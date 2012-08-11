{-# LANGUAGE TemplateHaskell #-}

module Data.Aeson.Schema.Choice.TH
  ( generateChoice
  ) where

import Control.Monad (forM)
import Language.Haskell.TH
import Data.Aeson (ToJSON (..), FromJSON (..))
import Control.Applicative (Alternative (..))

generateChoice :: Int -> Q [Dec]
generateChoice n | n < 2 = return []
generateChoice n = do
  tyName <- newName $ "Choice" ++ show n
  let tyParamNames = map (mkName . singleton) $ take n ['a'..]
  let tyParams = map varT tyParamNames
  conNames <- mapM newName $ map (\i -> "Choice" ++ show i ++ "of" ++ show n) [1..n]
  let cons = zipWith normalC conNames $ map ((:[]) . strictType notStrict) tyParams
  dataDec <- dataD (cxt []) tyName (map PlainTV tyParamNames) cons [''Eq, ''Ord, ''Show, ''Read]
  let tyCon = appConT tyName tyParams
  let genClassConstraints c = cxt $ map (classP c . singleton) tyParams
  instToJSON <- instanceD (genClassConstraints ''ToJSON)
                          (appT (conT ''ToJSON) tyCon)
                          [ funD 'toJSON $ zipWith genToJSONClause conNames tyParamNames ]
  instFromJSON <- instanceD (genClassConstraints ''FromJSON)
                            (appT (conT ''FromJSON) tyCon)
                            [ let v = mkName "v" in
                              funD 'parseJSON [clause [varP v]
                                                      (normalB $ foldl (\a b -> [e|(<|>)|] `appE` a `appE` b) (varE 'empty)
                                                               $ map (\con -> varE 'fmap `appE` conE con `appE` (varE 'parseJSON `appE` (varE v))) conNames)
                                                      []
                                              ]
                            ]
  let choiceN = mkName $ "choice" ++ show n
  let typeAs = mkNames 'a'
  let typeBs = mkNames 'b'
  choiceFunDec <- sigD choiceN
                     $ forallT (map PlainTV $ typeAs ++ typeBs)
                               (cxt [])
                             $ functionT (zipWith arrT (map varT typeAs) (map varT typeBs))
                                       $ appConT tyName (map varT typeAs) `arrT` appConT tyName (map varT typeBs)
  choiceFun <- funD choiceN
                  $ let f = mkName "f"
                        v = mkName "v"
                    in zipWith (\i con -> clause (replicate i wildP ++ [varP f] ++ replicate (n-i-1) wildP ++ [conP con [varP v]])
                                                 (normalB $ conE con `appE` (varE f `appE` varE v))
                                                 []) [0..] conNames
  choiceIofNFuns <- fmap concat $ forM (zip [1..n] conNames) $ \(i, con) -> do
    let choiceIofN = mkName $ "choice" ++ show i ++ "of" ++ show n ++ "s"
    typeDec <- sigD choiceIofN
                  $ forallT (map PlainTV $ tyParamNames)
                            (cxt [])
                          $ appT listT (appConT tyName (map varT tyParamNames)) `arrT` appT listT (tyParams !! (i-1))
    let cs = mkName "cs"
        c  = mkName "c"
    funDef <- funD choiceIofN
                   [clause [varP cs] (normalB $ compE [ bindS (conP con [varP c]) (varE cs)
                                                      , noBindS (varE c)
                                                      ]) []]
    return [typeDec, funDef]
  return $ [dataDec, instToJSON, instFromJSON, choiceFunDec, choiceFun] ++ choiceIofNFuns
  where
    singleton :: a -> [a]
    singleton = (:[])
    genToJSONClause :: Name -> Name -> ClauseQ
    genToJSONClause con param = clause [conP con [varP param]] (normalB . appE (varE 'toJSON) . varE $ param) []
    mkNames :: Char -> [Name]
    mkNames ch = map (mkName . (ch:) . show) [1..n]
    arrT :: TypeQ -> TypeQ -> TypeQ
    arrT a b = arrowT `appT` a `appT` b
    functionT :: [TypeQ] -> TypeQ -> TypeQ
    functionT ins out = foldr arrT out ins
    appConT :: Name -> [TypeQ] -> TypeQ
    appConT con params = foldl appT (conT con) params
