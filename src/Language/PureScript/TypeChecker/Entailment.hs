-- |
-- Type class entailment
--
module Language.PureScript.TypeChecker.Entailment
  ( Context
  , replaceTypeClassDictionaries
  ) where

import Prelude.Compat

import Control.Arrow (second)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.State
import Control.Monad.Supply.Class (MonadSupply(..))
import Control.Monad.Writer

import Data.Function (on)
import Data.List (minimumBy, sortBy, groupBy)
import Data.Maybe (maybeToList, mapMaybe)
import qualified Data.Map as M

import Language.PureScript.AST
import Language.PureScript.Crash
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.TypeChecker.Unify
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Types
import qualified Language.PureScript.Constants as C

-- | The 'Context' tracks those constraints which can be satisfied.
type Context = M.Map (Maybe ModuleName)
                     (M.Map Type
                            (M.Map (Qualified Ident)
                                   TypeClassDictionaryInScope))

-- | Merge two type class contexts
combineContexts :: Context -> Context -> Context
combineContexts = M.unionWith (M.unionWith M.union)

-- | Replace type class dictionary placeholders with inferred type class dictionaries
replaceTypeClassDictionaries
  :: (MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => Bool
  -> ModuleName
  -> Expr
  -> m (Expr, [(Ident, Constraint)])
replaceTypeClassDictionaries shouldGeneralize mn =
  let (_, f, _) = everywhereOnValuesTopDownM return (WriterT . go) return
  in flip evalStateT M.empty . runWriterT . f
  where
  go (TypeClassDictionary constraint dicts) = entails shouldGeneralize mn dicts constraint
  go other = return (other, [])

-- |
-- Check that the current set of type class dictionaries entail the specified type class goal, and, if so,
-- return a type class dictionary reference.
--
entails
  :: forall m
   . (MonadError MultipleErrors m, MonadWriter MultipleErrors m, MonadSupply m)
  => Bool
  -> ModuleName
  -> Context
  -> Constraint
  -> StateT Context m (Expr, [(Ident, Constraint)])
entails shouldGeneralize moduleName context = solve
  where
    forClassName :: Context -> Type -> [Type] -> [TypeClassDictionaryInScope]
    forClassName ctx hd tys = concatMap (findDicts ctx hd) (Nothing : map Just (mapMaybe ctorModules (hd : tys)))

    ctorModules :: Type -> Maybe ModuleName
    ctorModules (TypeConstructor (Qualified (Just mn) _)) = Just mn
    ctorModules (TypeConstructor (Qualified Nothing _)) = internalError "ctorModules: unqualified type name"
    ctorModules (TypeApp ty _) = ctorModules ty
    ctorModules _ = Nothing

    findDicts :: Context -> Type -> Maybe ModuleName -> [TypeClassDictionaryInScope]
    findDicts ctx cn = maybe [] M.elems . (>>= M.lookup cn) . flip M.lookup ctx

    solve :: Constraint -> StateT Context m (Expr, [(Ident, Constraint)])
    solve con = do
      (dict, unsolved) <- go 0 con
      return (dictionaryValueToValue dict, unsolved)
      where
      go :: Int -> Constraint -> StateT Context m (DictionaryValue, [(Ident, Constraint)])
      go work (Constraint conTy _) | work > 1000 = throwError . errorMessage $ PossiblyInfiniteInstance conTy
      go work con'@(Constraint conTy _) = do
        let (conHd, conTys) = stripTypeArguments [] conTy

            unique :: [(a, TypeClassDictionaryInScope)] -> m (Either (a, TypeClassDictionaryInScope) Constraint)
            unique [] | shouldGeneralize && all canBeGeneralized conTys = return (Right con')
                      | otherwise = throwError . errorMessage $ NoInstanceFound con'
            unique [a] = return $ Left a
            unique tcds | pairwise overlapping (map snd tcds) = do
                            tell . errorMessage $ OverlappingInstances conTy (map (tcdName . snd) tcds)
                            return $ Left (head tcds)
                        | otherwise = return $ Left (minimumBy (compare `on` length . tcdPath . snd) tcds)

        -- Get the inferred constraint context so far, and merge it with the global context
        inferred <- get
        let instances = do
              tcd <- forClassName (combineContexts context inferred) conHd conTys
              -- Make sure the type unifies with the type in the type instance definition
              subst <- maybeToList . (>>= verifySubstitution) . fmap concat $ zipWithM (typeHeadsAreEqual moduleName) conTys (tcdInstanceTypes tcd)
              return (subst, tcd)
        solution <- lift $ unique instances
        case solution of
          Left (subst, tcd) -> do
            -- Solve any necessary subgoals
            (args, unsolved) <- solveSubgoals subst (tcdDependencies tcd)
            let match = foldr (flip SubclassDictionaryValue)
                              (mkDictionary (tcdName tcd) args)
                              (tcdPath tcd)
            return (match, unsolved)
          Right unsolved@(Constraint unsolvedType _) -> do
            let (unsolvedHead, unsolvedTys) = stripTypeArguments [] unsolvedType
            -- Generate a fresh name for the unsolved constraint's new dictionary
            ident <- freshIdent "dict"
            let qident = Qualified Nothing ident
            -- Store the new dictionary in the Context so that we can solve this goal in
            -- future.
            let newDict = TypeClassDictionaryInScope qident [] unsolvedHead unsolvedTys Nothing
                newContext = M.singleton Nothing (M.singleton unsolvedHead (M.singleton qident newDict))
            modify (combineContexts newContext)
            return (LocalDictionaryValue qident, [(ident, unsolved)])
        where

        canBeGeneralized :: Type -> Bool
        canBeGeneralized TUnknown{} = True
        canBeGeneralized Skolem{} = True
        canBeGeneralized _ = False

        -- |
        -- Check if two dictionaries are overlapping
        --
        -- Dictionaries which are subclass dictionaries cannot overlap, since otherwise the overlap would have
        -- been caught when constructing superclass dictionaries.
        overlapping :: TypeClassDictionaryInScope -> TypeClassDictionaryInScope -> Bool
        overlapping TypeClassDictionaryInScope{ tcdPath = _ : _ } _ = False
        overlapping _ TypeClassDictionaryInScope{ tcdPath = _ : _ } = False
        overlapping TypeClassDictionaryInScope{ tcdDependencies = Nothing } _ = False
        overlapping _ TypeClassDictionaryInScope{ tcdDependencies = Nothing } = False
        overlapping tcd1 tcd2 = tcdName tcd1 /= tcdName tcd2

        -- Create dictionaries for subgoals which still need to be solved by calling go recursively
        -- E.g. the goal (Show a, Show b) => Show (Either a b) can be satisfied if the current type
        -- unifies with Either a b, and we can satisfy the subgoals Show a and Show b recursively.
        solveSubgoals :: [(String, Type)] -> Maybe [(Qualified (ProperName 'ClassName), [Type])] -> StateT Context m (Maybe [DictionaryValue], [(Ident, Constraint)])
        solveSubgoals _ Nothing = return (Nothing, [])
        solveSubgoals subst (Just subgoals) = do
            zipped <- traverse (go (work + 1) . toConstraint . second (map (replaceAllTypeVars subst))) subgoals
            let (dicts, unsolved) = unzip zipped
            return (Just dicts, concat unsolved)
          where
            toConstraint :: (Qualified (ProperName 'ClassName), [Type]) -> Constraint
            toConstraint (hd, tl) = Constraint (foldl TypeApp (TypeConstructor (fmap coerceProperName hd)) tl) Nothing

        -- Make a dictionary from subgoal dictionaries by applying the correct function
        mkDictionary :: Qualified Ident -> Maybe [DictionaryValue] -> DictionaryValue
        mkDictionary fnName Nothing = LocalDictionaryValue fnName
        mkDictionary fnName (Just []) = GlobalDictionaryValue fnName
        mkDictionary fnName (Just dicts) = DependentDictionaryValue fnName dicts

      -- Turn a DictionaryValue into a Expr
      dictionaryValueToValue :: DictionaryValue -> Expr
      dictionaryValueToValue (LocalDictionaryValue fnName) = Var fnName
      dictionaryValueToValue (GlobalDictionaryValue fnName) = Var fnName
      dictionaryValueToValue (DependentDictionaryValue fnName dicts) = foldl App (Var fnName) (map dictionaryValueToValue dicts)
      dictionaryValueToValue (SubclassDictionaryValue dict index) =
        App (Accessor (C.__superclass_ ++ show index)
                      (dictionaryValueToValue dict))
            valUndefined
      -- Ensure that a substitution is valid
      verifySubstitution :: [(String, Type)] -> Maybe [(String, Type)]
      verifySubstitution subst = do
        let grps = groupBy ((==) `on` fst) . sortBy (compare `on` fst) $ subst
        guard (all (pairwise unifiesWith . map snd) grps)
        return $ map head grps

    valUndefined :: Expr
    valUndefined = Var (Qualified (Just (ModuleName [ProperName C.prim])) (Ident C.undefined))

-- |
-- Check whether the type heads of two types are equal (for the purposes of type class dictionary lookup),
-- and return a substitution from type variables to types which makes the type heads unify.
--
typeHeadsAreEqual :: ModuleName -> Type -> Type -> Maybe [(String, Type)]
typeHeadsAreEqual m (KindedType t1 _) t2 = typeHeadsAreEqual m t1 t2
typeHeadsAreEqual m t1 (KindedType t2 _) = typeHeadsAreEqual m t1 t2
typeHeadsAreEqual _ (TUnknown u1)        (TUnknown u2)        | u1 == u2 = Just []
typeHeadsAreEqual _ (Skolem _ s1 _ _)    (Skolem _ s2 _ _)    | s1 == s2 = Just []
typeHeadsAreEqual _ t                    (TypeVar v)                     = Just [(v, t)]
typeHeadsAreEqual _ (TypeConstructor c1) (TypeConstructor c2) | c1 == c2 = Just []
typeHeadsAreEqual m (TypeApp h1 t1)      (TypeApp h2 t2)                 = (++) <$> typeHeadsAreEqual m h1 h2
                                                                                <*> typeHeadsAreEqual m t1 t2
typeHeadsAreEqual _ REmpty REmpty = Just []
typeHeadsAreEqual m r1@RCons{} r2@RCons{} =
  let (s1, r1') = rowToList r1
      (s2, r2') = rowToList r2

      int = [ (t1, t2) | (name, t1) <- s1, (name', t2) <- s2, name == name' ]
      sd1 = [ (name, t1) | (name, t1) <- s1, name `notElem` map fst s2 ]
      sd2 = [ (name, t2) | (name, t2) <- s2, name `notElem` map fst s1 ]
  in (++) <$> foldMap (uncurry (typeHeadsAreEqual m)) int
          <*> go sd1 r1' sd2 r2'
  where
  go :: [(String, Type)] -> Type -> [(String, Type)] -> Type -> Maybe [(String, Type)]
  go [] REmpty            [] REmpty            = Just []
  go [] (TUnknown _)      _  _                 = Just []
  go [] (TypeVar v1)      [] (TypeVar v2)      | v1 == v2 = Just []
  go [] (Skolem _ s1 _ _) [] (Skolem _ s2 _ _) | s1 == s2 = Just []
  go sd r                 [] (TypeVar v)       = Just [(v, rowFromList (sd, r))]
  go _  _                 _  _                 = Nothing
typeHeadsAreEqual _ _ _ = Nothing

-- |
-- Check all values in a list pairwise match a predicate
--
pairwise :: (a -> a -> Bool) -> [a] -> Bool
pairwise _ [] = True
pairwise _ [_] = True
pairwise p (x : xs) = all (p x) xs && pairwise p xs
