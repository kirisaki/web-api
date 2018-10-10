{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# OPTIONS_HADDOCK not-home    #-}
----------------------------------------------------------------------------
-- |
-- Module      :  Network.Api
-- Copyright   :  (c) Akihito KIRISAKI 2018
-- License     :  BSD3
--
-- Maintainer  :  Akihito KIRISAKI <kirisaki@klaraworks.net>
--
-----------------------------------------------------------------------------
module Network.Api.Request
  (
    Request(..)
  , Token(..)
  , Expiration(..)
  , ClientException(..)
  , call
  , buildHttpRequest
  , lookupMethod
  , injectUrlParams
  ) where

import           Network.Api.Header
import           Network.Api.Service

import           Control.Applicative
import           Control.Exception.Safe  as E
import           Data.Attoparsec.Text    as A
import qualified Data.ByteString         as BSS
import qualified Data.ByteString.Lazy    as BSL
import           Data.CaseInsensitive    (CI, mk, original)
import           Data.Either.Combinators
import           Data.Hashable
import           Data.List               as L
import           Data.Maybe
import           Data.Text               as T
import           Data.Text.Encoding
import           Data.Time.Clock
import           Data.Typeable           (Typeable)
import           GHC.Generics
import qualified Network.HTTP.Client     as C
import           Network.HTTP.Types.URI


-- | Call WebAPI
call :: Request -> Service -> IO BSL.ByteString
call req service = undefined

-- | Request to call API.
data Request = Request
  { method         :: HttpMethod
  , path           :: Text
  , pathParams     :: [(Text, Text)]
  , query          :: [(Text, Maybe Text)]
  , headers        :: Fields
  , body           :: BSS.ByteString
  , token          :: Maybe Token
  , alternativeUrl :: Maybe Text
  } deriving (Eq, Show)

-- | Build a Network.HTTP.Client.Request from Request.
buildHttpRequest :: (MonadThrow m) => Request -> Service -> m C.Request
buildHttpRequest req service = do
  method <- case lookupMethod req service of
         Just m  -> return m
         Nothing -> throw MethodNotDefined
  path <- case injectUrlParams (apiEndpoint method) (pathParams req) of
            Right r -> return r
            Left l  -> throw $ FailedToInjectUrlParams l
  let url = fromMaybe (baseUrl service) (T.stripSuffix "/" (baseUrl service)) `T.append` path
  let q = L.map (\(k, v) -> (percentEncode k, percentEncode <$> v)) (query req)
  hreq <- C.setQueryString q <$> C.parseUrlThrow (T.unpack url)
  return $ hreq { C.requestHeaders = toList' $ headers req }

percentEncode :: Text -> BSS.ByteString
percentEncode = urlEncode False . encodeUtf8


-- | Expiration of a token
data Expiration
  = ExpiresAt UTCTime
  | Indefinitely
  deriving (Eq, Show)

-- | Exceptions
data ClientException
  = MethodNotDefined
  | FailedToInjectUrlParams Text
  deriving(Show, Typeable)
instance Exception ClientException

-- | Token for authorization
data Token = Token
  { tokenText :: Text
  , expire    :: Maybe UTCTime
  } deriving (Eq, Show)

-- | Look up a method which matchs an API definition.
lookupMethod :: Request -> Service -> Maybe Method
lookupMethod req =
  let
    parseSegment i = feed (parse segment i) ""
    matchPath (Done "" (Raw "")) (Done "" (Raw "")) = True
    matchPath (Done reqRem reqSeg) (Done serRem serSeg) =
      case (reqSeg, serSeg) of
        (Param r, Param s) ->
          r == s &&  matchPath (parseSegment reqRem) (parseSegment serRem)
        (Raw _, Param _) ->
          matchPath (parseSegment reqRem) (parseSegment serRem)
        (Raw r, Raw s) ->
          r == s && matchPath (parseSegment reqRem) (parseSegment serRem)
        (Param _, Raw _) ->
           False
    matchParh _ _ = False
  in
    L.find (\m -> method req == httpMethod m
             && matchPath (Done (path req) (Raw "")) (Done (apiEndpoint m) (Raw ""))) . methods

-- | Inject parameters to a path represented with colon or braces.
injectUrlParams :: Text -> [(Text, Text)] -> Either Text Text
injectUrlParams path params =
  let
    inject (Right path, "") = Right path
    inject (Left e, _) = Left e
    inject (Right path, remain) =
      case feed (parse segment remain) "" of
        Done rem new ->
          case new of
            Param k ->
              case lookup k params of
                Just v ->
                  inject (Right (path `snoc` '/' `append` v), rem)
                Nothing ->
                  Left "lack parameters"
            Raw "" ->
              inject (Right path, rem)
            Raw t ->
              inject (Right (path `snoc` '/' `append` t), rem)
        _ ->
          Left "failed parsing"
  in
    inject (Right "", path)

-- Parsers
bracedParam :: Parser Segment
bracedParam = Param <$> (char '{' *> takeTill (== '}') <* char '}')

colonParam :: Parser Segment
colonParam = Param <$> (char ':' *> takeTill (== '/'))

rawPath :: Parser Segment
rawPath = Raw <$> (takeTill (== '/') <|> takeText)

data Segment = Param Text | Raw Text deriving(Eq, Show)

segment :: Parser Segment
segment =  skipWhile (== '/') *> (colonParam <|> bracedParam <|> rawPath) <* option '/' (char '/')