{-# LANGUAGE BangPatterns, CPP, ForeignFunctionInterface, GeneralizedNewtypeDeriving, MagicHash,
    UnliftedFFITypes #-}
#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif
-- |
-- Module      : Data.Text.Encoding
-- Copyright   : (c) 2009, 2010, 2011 Bryan O'Sullivan,
--               (c) 2009 Duncan Coutts,
--               (c) 2008, 2009 Tom Harper
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Portability : portable
--
-- Functions for converting 'Text' values to and from 'ByteString',
-- using several standard encodings.
--
-- To gain access to a much larger family of encodings, use the
-- <http://hackage.haskell.org/package/text-icu text-icu package>.

module Data.Text.Encoding
    (
    -- * Decoding ByteStrings to Text
    -- $strict
      decodeASCII
    , decodeLatin1
    , decodeUtf8
    , decodeUtf16LE
    , decodeUtf16BE
    , decodeUtf32LE
    , decodeUtf32BE

    -- ** Catchable failure
    , decodeUtf8'

    -- ** Controllable error handling
    , decodeUtf8With
    , decodeUtf16LEWith
    , decodeUtf16BEWith
    , decodeUtf32LEWith
    , decodeUtf32BEWith

    -- ** Stream oriented decoding
    -- $stream
    , streamDecodeUtf8
    , streamDecodeUtf8With
    , Decoding(..)

    -- * Encoding Text to ByteStrings
    , encodeUtf8
    , encodeUtf16LE
    , encodeUtf16BE
    , encodeUtf32LE
    , encodeUtf32BE

    -- * Encoding Text using ByteString Builders
    , encodeUtf8Builder
    , encodeUtf8BuilderEscaped
    ) where

#if __GLASGOW_HASKELL__ >= 702
import Control.Monad.ST.Unsafe (unsafeIOToST, unsafeSTToIO)
#else
import Control.Monad.ST (unsafeIOToST, unsafeSTToIO)
#endif

import Control.Exception (evaluate, try)
import Control.Monad.ST (runST)
import Data.Bits ((.&.))
import Data.ByteString as B
import Data.ByteString.Internal as B hiding (c2w)
import Data.Text.Encoding.Error (OnDecodeError, UnicodeException, strictDecode)
import Data.Text.Internal (Text(..), safe, text)
import Data.Text.Internal.Private (runText)
import Data.Text.Internal.Unsafe.Char (ord, unsafeWrite)
import Data.Text.Internal.Unsafe.Shift (shiftR)
import Data.Text.Show ()
import Data.Text.Unsafe (unsafeDupablePerformIO)
import Data.Word (Word8, Word32)
#if __GLASGOW_HASKELL__ >= 703
import Foreign.C.Types (CSize(CSize))
#else
import Foreign.C.Types (CSize)
#endif
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, minusPtr, nullPtr, plusPtr)
import Foreign.Storable (Storable, peek, poke)
import GHC.Base (ByteArray#, MutableByteArray#)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Builder.Internal as B hiding (empty, append)
import qualified Data.ByteString.Builder.Prim as BP
import qualified Data.ByteString.Builder.Prim.Internal as BP
import qualified Data.Text.Array as A
import qualified Data.Text.Internal.Encoding.Fusion as E
import qualified Data.Text.Internal.Encoding.Utf16 as U16
import qualified Data.Text.Internal.Fusion as F

#include "text_cbits.h"

-- $strict
--
-- All of the single-parameter functions for decoding bytestrings
-- encoded in one of the Unicode Transformation Formats (UTF) operate
-- in a /strict/ mode: each will throw an exception if given invalid
-- input.
--
-- Each function has a variant, whose name is suffixed with -'With',
-- that gives greater control over the handling of decoding errors.
-- For instance, 'decodeUtf8' will throw an exception, but
-- 'decodeUtf8With' allows the programmer to determine what to do on a
-- decoding error.

-- | /Deprecated/.  Decode a 'ByteString' containing 7-bit ASCII
-- encoded text.
decodeASCII :: ByteString -> Text
decodeASCII = decodeUtf8
{-# DEPRECATED decodeASCII "Use decodeUtf8 instead" #-}

-- | Decode a 'ByteString' containing Latin-1 (aka ISO-8859-1) encoded text.
--
-- 'decodeLatin1' is semantically equivalent to
--  @Data.Text.pack . Data.ByteString.Char8.unpack@
decodeLatin1 :: ByteString -> Text
decodeLatin1 s = F.unstream (E.streamASCII s)

-- | Decode a 'ByteString' containing UTF-8 encoded text.
decodeUtf8With :: OnDecodeError -> ByteString -> Text
decodeUtf8With onErr s@(PS fp off len) = runST $ do
  dest <- A.new len
  unsafeIOToST $ do
    withForeignPtr fp $ \ptr ->
      with (0::CSize) $ \destOffPtr ->do
        let curPtr = ptr `plusPtr` off
        let end = ptr `plusPtr` (off + len)
        curPtr' <- c_decode_utf8 (A.maBA dest) destOffPtr curPtr end
        if curPtr' == end
          then do
            n <- peek destOffPtr
            dest' <- unsafeSTToIO (A.unsafeFreeze dest)
            return (Text dest' 0 (fromIntegral n))
          else do
            return (F.unstream (E.streamUtf8 onErr s))
 where
  desc = "Data.Text.Internal.Encoding.decodeUtf8: Invalid UTF-8 stream"
{- INLINE[0] decodeUtf8With #-}

-- $stream
--
-- The 'streamDecodeUtf8' and 'streamDecodeUtf8With' functions accept
-- a 'ByteString' that represents a possibly incomplete input (e.g. a
-- packet from a network stream) that may not end on a UTF-8 boundary.
--
-- 1. The maximal prefix of 'Text' that could be decoded from the
--    given input.
--
-- 2. The suffix of the 'ByteString' that could not be decoded due to
--    insufficient input.
--
-- 3. A function that accepts another 'ByteString'.  That string will
--    be assumed to directly follow the string that was passed as
--    input to the original function, and it will in turn be decoded.
--
-- To help understand the use of these functions, consider the Unicode
-- string @\"hi &#9731;\"@. If encoded as UTF-8, this becomes @\"hi
-- \\xe2\\x98\\x83\"@; the final @\'&#9731;\'@ is encoded as 3 bytes.
--
-- Now suppose that we receive this encoded string as 3 packets that
-- are split up on untidy boundaries: @[\"hi \\xe2\", \"\\x98\",
-- \"\\x83\"]@. We cannot decode the entire Unicode string until we
-- have received all three packets, but we would like to make progress
-- as we receive each one.
--
-- @
-- ghci> let s0\@('Some' _ _ f0) = 'streamDecodeUtf8' \"hi \\xe2\"
-- ghci> s0
-- 'Some' \"hi \" \"\\xe2\" _
-- @
--
-- We use the continuation @f0@ to decode our second packet.
--
-- @
-- ghci> let s1\@('Some' _ _ f1) = f0 \"\\x98\"
-- ghci> s1
-- 'Some' \"\" \"\\xe2\\x98\"
-- @
--
-- We could not give @f0@ enough input to decode anything, so it
-- returned an empty string. Once we feed our second continuation @f1@
-- the last byte of input, it will make progress.
--
-- @
-- ghci> let s2\@('Some' _ _ f2) = f1 \"\\x83\"
-- ghci> s2
-- 'Some' \"\\x2603\" \"\" _
-- @
--
-- If given invalid input, an exception will be thrown by the function
-- or continuation where it is encountered.

-- | A stream oriented decoding result.
--
-- @since 1.0.0.0
data Decoding = Some Text ByteString (ByteString -> Decoding)

instance Show Decoding where
    showsPrec d (Some t bs _) = showParen (d > prec) $
                                showString "Some " . showsPrec prec' t .
                                showChar ' ' . showsPrec prec' bs .
                                showString " _"
      where prec = 10; prec' = prec + 1

newtype CodePoint = CodePoint Word32 deriving (Eq, Show, Num, Storable)
newtype DecoderState = DecoderState Word32 deriving (Eq, Show, Num, Storable)

-- | Decode, in a stream oriented way, a 'ByteString' containing UTF-8
-- encoded text that is known to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown (either by this function or a continuation) that cannot be
-- caught in pure code.  For more control over the handling of invalid
-- data, use 'streamDecodeUtf8With'.
--
-- @since 1.0.0.0
streamDecodeUtf8 :: ByteString -> Decoding
streamDecodeUtf8 = streamDecodeUtf8With strictDecode

-- | Decode, in a stream oriented way, a 'ByteString' containing UTF-8
-- encoded text.
--
-- @since 1.0.0.0
streamDecodeUtf8With :: OnDecodeError -> ByteString -> Decoding
streamDecodeUtf8With onErr = decodeChunk B.empty 0 0
 where
  -- We create a slightly larger than necessary buffer to accommodate a
  -- potential surrogate pair started in the last buffer
  decodeChunk :: ByteString -> CodePoint -> DecoderState -> ByteString
              -> Decoding
  decodeChunk undecoded0 codepoint0 state0 bs@(PS fp off len) =
    runST $ (unsafeIOToST . decodeChunkToBuffer) =<< A.new (len+1)
   where
    decodeChunkToBuffer :: A.MArray s -> IO Decoding
    decodeChunkToBuffer dest = withForeignPtr fp $ \ptr ->
      with (0::CSize) $ \destOffPtr ->
      with codepoint0 $ \codepointPtr ->
      with state0 $ \statePtr ->
      with nullPtr $ \curPtrPtr ->
        let end = ptr `plusPtr` (off + len)
            loop curPtr = do
              poke curPtrPtr curPtr
              curPtr' <- c_decode_utf8_with_state (A.maBA dest) destOffPtr
                         curPtrPtr end codepointPtr statePtr
              state <- peek statePtr
              case state of
                UTF8_REJECT -> do
                  -- We encountered an encoding error
                  x <- peek curPtr'
                  poke statePtr 0
                  case onErr desc (Just x) of
                    Nothing -> loop $ curPtr' `plusPtr` 1
                    Just c -> do
                      destOff <- peek destOffPtr
                      w <- unsafeSTToIO $
                           unsafeWrite dest (fromIntegral destOff) (safe c)
                      poke destOffPtr (destOff + fromIntegral w)
                      loop $ curPtr' `plusPtr` 1

                _ -> do
                  -- We encountered the end of the buffer while decoding
                  n <- peek destOffPtr
                  codepoint <- peek codepointPtr
                  chunkText <- unsafeSTToIO $ do
                      arr <- A.unsafeFreeze dest
                      return $! text arr 0 (fromIntegral n)
                  lastPtr <- peek curPtrPtr
                  let left = lastPtr `minusPtr` curPtr
                      !undecoded = case state of
                        UTF8_ACCEPT -> B.empty
                        _           -> B.append undecoded0 (B.drop left bs)
                  return $ Some chunkText undecoded
                           (decodeChunk undecoded codepoint state)
        in loop (ptr `plusPtr` off)
  desc = "Data.Text.Internal.Encoding.streamDecodeUtf8With: Invalid UTF-8 stream"

-- | Decode a 'ByteString' containing UTF-8 encoded text that is known
-- to be valid.
--
-- If the input contains any invalid UTF-8 data, an exception will be
-- thrown that cannot be caught in pure code.  For more control over
-- the handling of invalid data, use 'decodeUtf8'' or
-- 'decodeUtf8With'.
decodeUtf8 :: ByteString -> Text
decodeUtf8 = decodeUtf8With strictDecode
{-# INLINE[0] decodeUtf8 #-}
{-# RULES "STREAM stream/decodeUtf8 fusion" [1]
    forall bs. F.stream (decodeUtf8 bs) = E.streamUtf8 strictDecode bs #-}

-- | Decode a 'ByteString' containing UTF-8 encoded text.
--
-- If the input contains any invalid UTF-8 data, the relevant
-- exception will be returned, otherwise the decoded text.
decodeUtf8' :: ByteString -> Either UnicodeException Text
decodeUtf8' = unsafeDupablePerformIO . try . evaluate . decodeUtf8With strictDecode
{-# INLINE decodeUtf8' #-}

-- | Encode text to a ByteString 'B.Builder' using UTF-8 encoding.
--
-- @since 1.1.0.0
encodeUtf8Builder :: Text -> B.Builder
encodeUtf8Builder = \t -> B.builder (textCopyStep t)
{-# INLINE encodeUtf8Builder #-}

textCopyStep :: Text -> B.BuildStep a -> B.BuildStep a
textCopyStep !(Text arr off len) k = go 0 len
  where
    go !ip !ipe !(B.BufferRange op ope)
      | inpRemaining <= outRemaining = do
        A.copyToPtr op 0 arr (off + ip) inpRemaining
        let !br' = B.BufferRange (op `plusPtr` inpRemaining) ope
        k br'
      | otherwise = do
        A.copyToPtr op 0 arr (off + ip) outRemaining
        let !ip' = ip + outRemaining
        return $ B.bufferFull 1 ope (go ip' ipe)
      where
        outRemaining = ope `minusPtr` op
        inpRemaining = ipe - ip
{-# INLINE textCopyStep #-}

-- | Encode text using UTF-8 encoding and escape the ASCII characters using
-- a 'BP.BoundedPrim'.
--
-- Use this function is to implement efficient encoders for text-based formats
-- like JSON or HTML.
--
-- @since 1.1.0.0
{-# INLINE encodeUtf8BuilderEscaped #-}
-- TODO: Extend documentation with references to source code in @blaze-html@
-- or @aeson@ that uses this function.
encodeUtf8BuilderEscaped :: BP.BoundedPrim Word8 -> Text -> B.Builder
encodeUtf8BuilderEscaped be =
    -- manual eta-expansion to ensure inlining works as expected
    \txt -> B.builder (mkBuildstep txt)
  where
    bound = max 4 $ BP.sizeBound be

    mkBuildstep (Text arr off len) !k =
        outerLoop off
      where
        iend = off + len

        outerLoop !i0 !br@(B.BufferRange op0 ope)
          | i0 >= iend       = k br
          | outRemaining > 0 = goPartial (i0 + min outRemaining inpRemaining)
          -- TODO: Use a loop with an integrated bound's check if outRemaining
          -- is smaller than 8, as this will save on divisions.
          | otherwise        = return $ B.bufferFull bound op0 (outerLoop i0)
          where
            outRemaining = (ope `minusPtr` op0) `div` bound
            inpRemaining = iend - i0

            goPartial !iendTmp = go i0 op0
              where
                go !i !op
                  | i < iendTmp = case a of
                      a | a <= 0x7F ->
                            BP.runB be (fromIntegral a) op >>= go (i + 1)
                        | 0xC2 <= a && a <= 0xDF -> do
                            poke8 0 a
                            poke8 1 b
                            go (i + 2) (op `plusPtr` 2)
                        | 0xE0 <= a && a <= 0xEF -> do
                            poke8 0 a
                            poke8 1 b
                            poke8 2 c
                            go (i + 3) (op `plusPtr` 3)
                        | otherwise -> do
                            poke8 0 a
                            poke8 1 b
                            poke8 2 c
                            poke8 3 d
                            go (i + 4) (op `plusPtr` 4)
                  | otherwise =
                      outerLoop i (B.BufferRange op ope)
                  where
                    poke8 j v = poke (op `plusPtr` j) (fromIntegral v :: Word8)
                    a = A.unsafeIndex arr i
                    b = A.unsafeIndex arr (i+1)
                    c = A.unsafeIndex arr (i+2)
                    d = A.unsafeIndex arr (i+3)


-- | Encode text using UTF-8 encoding.
encodeUtf8 :: Text -> ByteString
encodeUtf8 (Text arr off len)
  | len == 0  = B.empty
  | otherwise = B.unsafeCreate len (\op -> A.copyToPtr op 0 arr off len)

-- | Decode text from little endian UTF-16 encoding.
decodeUtf16LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16LEWith onErr bs = F.unstream (E.streamUtf16LE onErr bs)
{-# INLINE decodeUtf16LEWith #-}

-- | Decode text from little endian UTF-16 encoding.
--
-- If the input contains any invalid little endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16LEWith'.
decodeUtf16LE :: ByteString -> Text
decodeUtf16LE = decodeUtf16LEWith strictDecode
{-# INLINE decodeUtf16LE #-}

-- | Decode text from big endian UTF-16 encoding.
decodeUtf16BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf16BEWith onErr bs = F.unstream (E.streamUtf16BE onErr bs)
{-# INLINE decodeUtf16BEWith #-}

-- | Decode text from big endian UTF-16 encoding.
--
-- If the input contains any invalid big endian UTF-16 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf16BEWith'.
decodeUtf16BE :: ByteString -> Text
decodeUtf16BE = decodeUtf16BEWith strictDecode
{-# INLINE decodeUtf16BE #-}

-- | Encode text using little endian UTF-16 encoding.
encodeUtf16LE :: Text -> ByteString
encodeUtf16LE txt = E.unstream (E.restreamUtf16LE (F.stream txt))
{-# INLINE encodeUtf16LE #-}

-- | Encode text using big endian UTF-16 encoding.
encodeUtf16BE :: Text -> ByteString
encodeUtf16BE txt = E.unstream (E.restreamUtf16BE (F.stream txt))
{-# INLINE encodeUtf16BE #-}

-- | Decode text from little endian UTF-32 encoding.
decodeUtf32LEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32LEWith onErr bs = F.unstream (E.streamUtf32LE onErr bs)
{-# INLINE decodeUtf32LEWith #-}

-- | Decode text from little endian UTF-32 encoding.
--
-- If the input contains any invalid little endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32LEWith'.
decodeUtf32LE :: ByteString -> Text
decodeUtf32LE = decodeUtf32LEWith strictDecode
{-# INLINE decodeUtf32LE #-}

-- | Decode text from big endian UTF-32 encoding.
decodeUtf32BEWith :: OnDecodeError -> ByteString -> Text
decodeUtf32BEWith onErr bs = F.unstream (E.streamUtf32BE onErr bs)
{-# INLINE decodeUtf32BEWith #-}

-- | Decode text from big endian UTF-32 encoding.
--
-- If the input contains any invalid big endian UTF-32 data, an
-- exception will be thrown.  For more control over the handling of
-- invalid data, use 'decodeUtf32BEWith'.
decodeUtf32BE :: ByteString -> Text
decodeUtf32BE = decodeUtf32BEWith strictDecode
{-# INLINE decodeUtf32BE #-}

-- | Encode text using little endian UTF-32 encoding.
encodeUtf32LE :: Text -> ByteString
encodeUtf32LE txt = E.unstream (E.restreamUtf32LE (F.stream txt))
{-# INLINE encodeUtf32LE #-}

-- | Encode text using big endian UTF-32 encoding.
encodeUtf32BE :: Text -> ByteString
encodeUtf32BE txt = E.unstream (E.restreamUtf32BE (F.stream txt))
{-# INLINE encodeUtf32BE #-}

foreign import ccall unsafe "_hs_text_decode_utf8" c_decode_utf8
    :: MutableByteArray# s -> Ptr CSize
    -> Ptr Word8 -> Ptr Word8 -> IO (Ptr Word8)

foreign import ccall unsafe "_hs_text_decode_utf8_state" c_decode_utf8_with_state
    :: MutableByteArray# s -> Ptr CSize
    -> Ptr (Ptr Word8) -> Ptr Word8
    -> Ptr CodePoint -> Ptr DecoderState -> IO (Ptr Word8)
