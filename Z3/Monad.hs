
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}
  -- This is just to avoid warnings because we import fragile new Z3 API stuff
  -- from Z3.Base

-- TODO: Error handling

-- |
-- Module    : Z3.Monad
-- Copyright : (c) Iago Abal, 2013
--             (c) David Castro, 2013
-- License   : BSD3
-- Maintainer: Iago Abal <iago.abal@gmail.com>,
--             David Castro <david.castro.dcp@gmail.com>
--
-- A simple monadic wrapper for 'Z3.Base'.

module Z3.Monad
  ( MonadZ3(..)
  , Z3
  , module Z3.Opts
  , Logic(..)
  , evalZ3
  , evalZ3With

  -- * Types
  , Symbol
  , AST
  , Sort
  , FuncDecl
  , App
  , Pattern
  , Model
  , FuncInterp
  , FuncEntry
  , FuncModel(..)

  -- ** Satisfiability result
  , Result(..)

  -- * Symbols
  , mkIntSymbol
  , mkStringSymbol

  -- * Sorts
  , mkUninterpretedSort
  , mkBoolSort
  , mkIntSort
  , mkRealSort
  , mkArraySort

  -- * Constants and Applications
  , mkFuncDecl
  , mkApp
  , mkConst
  , mkTrue
  , mkFalse
  , mkEq
  , mkNot
  , mkIte
  , mkIff
  , mkImplies
  , mkXor
  , mkAnd
  , mkOr
  , mkDistinct
  , mkAdd
  , mkMul
  , mkSub
  , mkUnaryMinus
  , mkDiv
  , mkMod
  , mkRem
  , mkLt
  , mkLe
  , mkGt
  , mkGe
  , mkInt2Real
  , mkReal2Int
  , mkIsInt

  -- * Arrays
  , mkSelect
  , mkStore
  , mkConstArray
  , mkMap
  , mkArrayDefault

  -- * Numerals
  , mkNumeral
  , mkInt
  , mkReal

  -- * Quantifiers
  , mkPattern
  , mkBound
  , mkForall
  , mkExists

  -- * Accessors
  , getBool
  , getInt
  , getReal

  -- * Models
  , eval
  , evalT
  , evalFunc
  , evalArray
  , showModel
  , showContext
  , getFuncInterp
  , isAsArray
  , getAsArrayFuncDecl
  , funcInterpGetNumEntries
  , funcInterpGetEntry
  , funcInterpGetElse
  , funcInterpGetArity
  , funcEntryGetValue
  , funcEntryGetNumArgs
  , funcEntryGetArg

  -- * Constraints
  , assertCnstr
  , check
  , getModel
  , delModel
  , withModel
  , push
  , pop

  -- * String Conversion
  , ASTPrintMode(..)
  , setASTPrintMode
  , astToString
  , patternToString
  , sortToString
  , funcDeclToString
  , benchmarkToSMTLibString
  )
  where

import Z3.Opts
import Z3.Base
  ( Symbol
  , AST
  , Sort
  , FuncDecl
  , App
  , Pattern
  , Model
  , FuncInterp
  , FuncEntry
  , FuncModel(..)
  , Result(..)
  , Logic(..)
  , ASTPrintMode(..)
  )
import qualified Z3.Base as Base

import Control.Applicative ( Applicative )
import Control.Monad ( void )
import Control.Monad.Reader ( ReaderT, runReaderT, asks )
import Control.Monad.Trans ( MonadIO, liftIO )
import Data.Traversable ( Traversable )
import qualified Data.Traversable as T

---------------------------------------------------------------------
-- The Z3 monad-class

class (Monad m, MonadIO m) => MonadZ3 m where
  getSolver  :: m (Maybe Base.Solver)
  getContext :: m Base.Context

-------------------------------------------------
-- Lifting

liftScalar :: MonadZ3 z3 => (Base.Context -> IO b) -> z3 b
liftScalar f = liftIO . f =<< getContext

liftFun1 :: MonadZ3 z3 => (Base.Context -> a -> IO b) -> a -> z3 b
liftFun1 f a = getContext >>= \ctx -> liftIO (f ctx a)

liftFun2 :: MonadZ3 z3 => (Base.Context -> a -> b -> IO c) -> a -> b -> z3 c
liftFun2 f a b = getContext >>= \ctx -> liftIO (f ctx a b)

liftFun3 :: MonadZ3 z3 => (Base.Context -> a -> b -> c -> IO d)
                              -> a -> b -> c -> z3 d
liftFun3 f a b c = getContext >>= \ctx -> liftIO (f ctx a b c)

liftFun4 :: MonadZ3 z3 => (Base.Context -> a -> b -> c -> d -> IO e)
                -> a -> b -> c -> d -> z3 e
liftFun4 f a b c d = getContext >>= \ctx -> liftIO (f ctx a b c d)

liftFun6 :: MonadZ3 z3 =>
              (Base.Context -> a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> IO b)
                -> a1 -> a2 -> a3 -> a4 -> a5 -> a6 -> z3 b
liftFun6 f x1 x2 x3 x4 x5 x6 =
  getContext >>= \ctx -> liftIO (f ctx x1 x2 x3 x4 x5 x6)

liftSolver0 :: MonadZ3 z3 =>
       (Base.Context -> Base.Solver -> IO b)
    -> (Base.Context -> IO b)
    -> z3 b
liftSolver0 f_s f_no_s =
  do ctx <- getContext
     liftIO . maybe (f_no_s ctx) (f_s ctx) =<< getSolver

liftSolver1 :: MonadZ3 z3 =>
       (Base.Context -> Base.Solver -> a -> IO b)
    -> (Base.Context -> a -> IO b)
    -> a -> z3 b
liftSolver1 f_s f_no_s a =
  do ctx <- getContext
     liftIO . maybe (f_no_s ctx a) (\s -> f_s ctx s a) =<< getSolver

-------------------------------------------------
-- A simple Z3 monad.

newtype Z3 a = Z3 { _unZ3 :: ReaderT Z3Env IO a }
    deriving (Functor, Applicative, Monad, MonadIO)

data Z3Env
  = Z3Env {
      envSolver  :: Maybe Base.Solver
    , envContext :: Base.Context
    }

instance MonadZ3 Z3 where
  getSolver  = Z3 $ asks envSolver
  getContext = Z3 $ asks envContext

-- | Eval a Z3 script.
evalZ3With :: Maybe Logic -> Opts -> Z3 a -> IO a
evalZ3With mbLogic opts (Z3 s) =
  Base.withConfig $ \cfg -> do
    setOpts cfg opts
    Base.withContext cfg $ \ctx -> do
      mbSolver <- T.mapM (Base.mkSolverForLogic ctx) mbLogic
      runReaderT s (Z3Env mbSolver ctx)

-- | Eval a Z3 script with default configuration options.
evalZ3 :: Z3 a -> IO a
evalZ3 = evalZ3With Nothing stdOpts

---------------------------------------------------------------------
-- Symbols

-- | Create a Z3 symbol using an integer.
mkIntSymbol :: (MonadZ3 z3, Integral i) => i -> z3 Symbol
mkIntSymbol = liftFun1 Base.mkIntSymbol

-- | Create a Z3 symbol using a string.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gafebb0d3c212927cf7834c3a20a84ecae>
mkStringSymbol :: MonadZ3 z3 => String -> z3 Symbol
mkStringSymbol = liftFun1 Base.mkStringSymbol

---------------------------------------------------------------------
-- Sorts

-- | Create a free (uninterpreted) type using the given name (symbol).
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga736e88741af1c178cbebf94c49aa42de>
mkUninterpretedSort :: MonadZ3 z3 => Symbol -> z3 Sort
mkUninterpretedSort = liftFun1 Base.mkUninterpretedSort

-- | Create the /boolean/ type.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gacdc73510b69a010b71793d429015f342>
mkBoolSort :: MonadZ3 z3 => z3 Sort
mkBoolSort = liftScalar Base.mkBoolSort

-- | Create the /integer/ type.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga6cd426ab5748653b77d389fd3eac1015>
mkIntSort :: MonadZ3 z3 => z3 Sort
mkIntSort = liftScalar Base.mkIntSort

-- | Create the /real/ type.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga40ef93b9738485caed6dc84631c3c1a0>
mkRealSort :: MonadZ3 z3 => z3 Sort
mkRealSort = liftScalar Base.mkRealSort

-- | Create an array type
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gafe617994cce1b516f46128e448c84445>
--
mkArraySort :: MonadZ3 z3 => Sort -> Sort -> z3 Sort
mkArraySort = liftFun2 Base.mkArraySort


---------------------------------------------------------------------
-- Constants and Applications

-- | A Z3 function
mkFuncDecl :: MonadZ3 z3 => Symbol -> [Sort] -> Sort -> z3 FuncDecl
mkFuncDecl = liftFun3 Base.mkFuncDecl

-- | Create a constant or function application.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga33a202d86bf628bfab9b6f437536cebe>
mkApp :: MonadZ3 z3 => FuncDecl -> [AST] -> z3 AST
mkApp = liftFun2 Base.mkApp

-- | Declare and create a constant.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga093c9703393f33ae282ec5e8729354ef>
mkConst :: MonadZ3 z3 => Symbol -> Sort -> z3 AST
mkConst = liftFun2 Base.mkConst

-- | Create an AST node representing /true/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gae898e7380409bbc57b56cc5205ef1db7>
mkTrue :: MonadZ3 z3 => z3 AST
mkTrue = liftScalar Base.mkTrue

-- | Create an AST node representing /false/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga5952ac17671117a02001fed6575c778d>
mkFalse :: MonadZ3 z3 => z3 AST
mkFalse = liftScalar Base.mkFalse

-- | Create an AST node representing /l = r/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga95a19ce675b70e22bb0401f7137af37c>
mkEq :: MonadZ3 z3 => AST -> AST -> z3 AST
mkEq = liftFun2 Base.mkEq

-- | The distinct construct is used for declaring the arguments pairwise
-- distinct.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaa076d3a668e0ec97d61744403153ecf7>
mkDistinct :: MonadZ3 z3 => [AST] -> z3 AST
mkDistinct = liftFun1 Base.mkDistinct

-- | Create an AST node representing /not(a)/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga3329538091996eb7b3dc677760a61072>
mkNot :: MonadZ3 z3 => AST -> z3 AST
mkNot = liftFun1 Base.mkNot

-- | Create an AST node representing an if-then-else: /ite(t1, t2, t3)/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga94417eed5c36e1ad48bcfc8ad6e83547>
mkIte :: MonadZ3 z3 => AST -> AST -> AST -> z3 AST
mkIte = liftFun3 Base.mkIte

-- | Create an AST node representing /t1 iff t2/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga930a8e844d345fbebc498ac43a696042>
mkIff :: MonadZ3 z3 => AST -> AST -> z3 AST
mkIff = liftFun2 Base.mkIff

-- | Create an AST node representing /t1 implies t2/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gac829c0e25bbbd30343bf073f7b524517>
mkImplies :: MonadZ3 z3 => AST -> AST -> z3 AST
mkImplies = liftFun2 Base.mkImplies

-- | Create an AST node representing /t1 xor t2/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gacc6d1b848032dec0c4617b594d4229ec>
mkXor :: MonadZ3 z3 => AST -> AST -> z3 AST
mkXor = liftFun2 Base.mkXor

-- | Create an AST node representing args[0] and ... and args[num_args-1].
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gacde98ce4a8ed1dde50b9669db4838c61>
mkAnd :: MonadZ3 z3 => [AST] -> z3 AST
mkAnd = liftFun1 Base.mkAnd

-- | Create an AST node representing args[0] or ... or args[num_args-1].
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga00866d16331d505620a6c515302021f9>
mkOr :: MonadZ3 z3 => [AST] -> z3 AST
mkOr = liftFun1 Base.mkOr

-- | Create an AST node representing args[0] + ... + args[num_args-1].
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga4e4ac0a4e53eee0b4b0ef159ed7d0cd5>
mkAdd :: MonadZ3 z3 => [AST] -> z3 AST
mkAdd = liftFun1 Base.mkAdd

-- | Create an AST node representing args[0] * ... * args[num_args-1].
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gab9affbf8401a18eea474b59ad4adc890>
mkMul :: MonadZ3 z3 => [AST] -> z3 AST
mkMul = liftFun1 Base.mkMul

-- | Create an AST node representing args[0] - ... - args[num_args - 1].
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga4f5fea9b683f9e674fd8f14d676cc9a9>
mkSub :: MonadZ3 z3 => [AST] -> z3 AST
mkSub = liftFun1 Base.mkSub

-- | Create an AST node representing -arg.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gadcd2929ad732937e25f34277ce4988ea>
mkUnaryMinus :: MonadZ3 z3 => AST -> z3 AST
mkUnaryMinus = liftFun1 Base.mkUnaryMinus

-- | Create an AST node representing arg1 div arg2.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga1ac60ee8307af8d0b900375914194ff3>
mkDiv :: MonadZ3 z3 => AST -> AST -> z3 AST
mkDiv = liftFun2 Base.mkDiv

-- | Create an AST node representing arg1 mod arg2.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga8e350ac77e6b8fe805f57efe196e7713>
mkMod :: MonadZ3 z3 => AST -> AST -> z3 AST
mkMod = liftFun2 Base.mkMod

-- | Create an AST node representing arg1 rem arg2.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga2fcdb17f9039bbdaddf8a30d037bd9ff>
mkRem :: MonadZ3 z3 => AST -> AST -> z3 AST
mkRem = liftFun2 Base.mkRem

-- | Create less than.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga58a3dc67c5de52cf599c346803ba1534>
mkLt :: MonadZ3 z3 => AST -> AST -> z3 AST
mkLt = liftFun2 Base.mkLt

-- | Create less than or equal to.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaa9a33d11096841f4e8c407f1578bc0bf>
mkLe :: MonadZ3 z3 => AST -> AST -> z3 AST
mkLe = liftFun2 Base.mkLe

-- | Create greater than.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga46167b86067586bb742c0557d7babfd3>
mkGt :: MonadZ3 z3 => AST -> AST -> z3 AST
mkGt = liftFun2 Base.mkGt

-- | Create greater than or equal to.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gad9245cbadb80b192323d01a8360fb942>
mkGe :: MonadZ3 z3 => AST -> AST -> z3 AST
mkGe = liftFun2 Base.mkGe

-- | Coerce an integer to a real.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga7130641e614c7ebafd28ae16a7681a21>
mkInt2Real :: MonadZ3 z3 => AST -> z3 AST
mkInt2Real = liftFun1 Base.mkInt2Real

-- | Coerce a real to an integer.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga759b6563ba1204aae55289009a3fdc6d>
mkReal2Int :: MonadZ3 z3 => AST -> z3 AST
mkReal2Int = liftFun1 Base.mkReal2Int

-- | Check if a real number is an integer.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaac2ad0fb04e4900fdb4add438d137ad3>
mkIsInt :: MonadZ3 z3 => AST -> z3 AST
mkIsInt = liftFun1 Base.mkIsInt

---------------------------------------------------------------------
-- Arrays

-- | Array read. The argument a is the array and i is the index of the array
-- that gets read.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga38f423f3683379e7f597a7fe59eccb67>
mkSelect :: MonadZ3 z3 => AST -> AST -> z3 AST
mkSelect = liftFun2 Base.mkSelect

-- | Array update.   
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gae305a4f54b4a64f7e5973ae6ccb13593>
mkStore :: MonadZ3 z3 => AST -> AST -> AST -> z3 AST
mkStore = liftFun3 Base.mkStore

-- | Create the constant array.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga84ea6f0c32b99c70033feaa8f00e8f2d>
mkConstArray :: MonadZ3 z3 => Sort -> AST -> z3 AST
mkConstArray = liftFun2 Base.mkConstArray

-- | map f on the the argument arrays.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga9150242d9430a8c3d55d2ca3b9a4362d>
mkMap :: MonadZ3 z3 => FuncDecl -> Int -> [AST] -> z3 AST
mkMap = liftFun3 Base.mkMap

-- | Access the array default value. Produces the default range value, for
-- arrays that can be represented as finite maps with a default range value.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga78e89cca82f0ab4d5f4e662e5e5fba7d>
mkArrayDefault :: MonadZ3 z3 => AST -> z3 AST
mkArrayDefault = liftFun1 Base.mkArrayDefault

---------------------------------------------------------------------
-- Numerals

-- | Create a numeral of a given sort.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gac8aca397e32ca33618d8024bff32948c>
mkNumeral :: MonadZ3 z3 => String -> Sort -> z3 AST
mkNumeral = liftFun2 Base.mkNumeral

-------------------------------------------------
-- Numerals / Integers

-- | Create a numeral of sort /int/.
mkInt :: (MonadZ3 z3, Integral a) => a -> z3 AST
mkInt = liftFun1 Base.mkInt

-------------------------------------------------
-- Numerals / Reals

-- | Create a numeral of sort /real/.
mkReal :: (MonadZ3 z3, Real r) => r -> z3 AST
mkReal = liftFun1 Base.mkReal

---------------------------------------------------------------------
-- Quantifiers

mkPattern :: MonadZ3 z3 => [AST] -> z3 Pattern
mkPattern = liftFun1 Base.mkPattern

mkBound :: MonadZ3 z3 => Int -> Sort -> z3 AST
mkBound = liftFun2 Base.mkBound

mkForall :: MonadZ3 z3 => [Pattern] -> [Symbol] -> [Sort] -> AST -> z3 AST
mkForall = liftFun4 Base.mkForall

mkExists :: MonadZ3 z3 => [Pattern] -> [Symbol] -> [Sort] -> AST -> z3 AST
mkExists = liftFun4 Base.mkExists

---------------------------------------------------------------------
-- Accessors

-- | Returns @Just True@, @Just False@, or @Nothing@ for /undefined/.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga133aaa1ec31af9b570ed7627a3c8c5a4>
getBool :: MonadZ3 z3 => AST -> z3 (Maybe Bool)
getBool = liftFun1 Base.getBool

-- | Return the integer value
getInt :: MonadZ3 z3 => AST -> z3 Integer
getInt = liftFun1 Base.getInt

-- | Return rational value
getReal :: MonadZ3 z3 => AST -> z3 Rational
getReal = liftFun1 Base.getReal

---------------------------------------------------------------------
-- Models

-- | Evaluate an AST node in the given model.
eval :: MonadZ3 z3 => Model -> AST -> z3 (Maybe AST)
eval = liftFun2 Base.eval

-- | Evaluate a collection of AST nodes in the given model.
evalT :: (MonadZ3 z3,Traversable t) => Model -> t AST -> z3 (Maybe (t AST))
evalT = liftFun2 Base.evalT

-- | Get function as a list of argument/value pairs.
evalFunc :: MonadZ3 z3 => Model -> FuncDecl -> z3 (Maybe FuncModel)
evalFunc = liftFun2 Base.evalFunc

-- | Get array as a list of argument/value pairs, if it is
-- represented as a function (ie, using as-array).
evalArray :: MonadZ3 z3 => Model -> AST -> z3 (Maybe FuncModel)
evalArray = liftFun2 Base.evalArray

-- | Return the interpretation of the function f in the model m.
-- Return NULL, if the model does not assign an interpretation for f.
-- That should be interpreted as: the f does not matter.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gafb9cc5eca9564d8a849c154c5a4a8633>
getFuncInterp :: MonadZ3 z3 => Model -> FuncDecl -> z3 (Maybe FuncInterp)
getFuncInterp = liftFun2 Base.getFuncInterp

-- | The (_ as-array f) AST node is a construct for assigning interpretations
-- for arrays in Z3. It is the array such that forall indices i we have that
-- (select (_ as-array f) i) is equal to (f i). This procedure returns Z3_TRUE
-- if the a is an as-array AST node.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga4674da67d226bfb16861829b9f129cfa>
isAsArray :: MonadZ3 z3 => AST -> z3 Bool
isAsArray = liftFun1 Base.isAsArray

-- | Return the function declaration f associated with a (_ as_array f) node.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga7d9262dc6e79f2aeb23fd4a383589dda>
getAsArrayFuncDecl :: MonadZ3 z3 => AST -> z3 FuncDecl
getAsArrayFuncDecl = liftFun1 Base.getAsArrayFuncDecl

-- | Return the number of entries in the given function interpretation.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga2bab9ae1444940e7593729beec279844>
funcInterpGetNumEntries :: MonadZ3 z3 => FuncInterp -> z3 Int
funcInterpGetNumEntries = liftFun1 Base.funcInterpGetNumEntries

-- | Return a "point" of the given function intepretation.
-- It represents the value of f in a particular point.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaf157e1e1cd8c0cfe6a21be6370f659da>
funcInterpGetEntry :: MonadZ3 z3 => FuncInterp -> Int -> z3 FuncEntry
funcInterpGetEntry = liftFun2 Base.funcInterpGetEntry

-- | Return the 'else' value of the given function interpretation.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga46de7559826ba71b8488d727cba1fb64>
funcInterpGetElse :: MonadZ3 z3 => FuncInterp -> z3 AST
funcInterpGetElse = liftFun1 Base.funcInterpGetElse

-- | Return the arity (number of arguments) of the given function
-- interpretation.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaca22cbdb6f7787aaae5d814f2ab383d8>
funcInterpGetArity :: MonadZ3 z3 => FuncInterp -> z3 Int
funcInterpGetArity = liftFun1 Base.funcInterpGetArity

-- | Return the value of this point.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga9fd65e2ab039aa8e40608c2ecf7084da>
funcEntryGetValue :: MonadZ3 z3 => FuncEntry -> z3 AST
funcEntryGetValue = liftFun1 Base.funcEntryGetValue

-- | Return the number of arguments in a Z3_func_entry object.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga51aed8c5bc4b1f53f0c371312de3ce1a>
funcEntryGetNumArgs :: MonadZ3 z3 => FuncEntry -> z3 Int
funcEntryGetNumArgs = liftFun1 Base.funcEntryGetNumArgs

-- | Return an argument of a Z3_func_entry object.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga6fe03fe3c824fceb52766a4d8c2cbeab>
funcEntryGetArg :: MonadZ3 z3 => FuncEntry -> Int -> z3 AST
funcEntryGetArg = liftFun2 Base.funcEntryGetArg

---------------------------------------------------------------------
-- Constraints

-- | Create a backtracking point.
push :: MonadZ3 z3 => z3 ()
push = liftSolver0 Base.solverPush Base.push

-- | Backtrack /n/ backtracking points.
pop :: MonadZ3 z3 => Int -> z3 ()
pop = liftSolver1 Base.solverPop Base.pop

-- | Assert a constraing into the logical context.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga1a05ff73a564ae7256a2257048a4680a>
assertCnstr :: MonadZ3 z3 => AST -> z3 ()
assertCnstr = liftSolver1 Base.solverAssertCnstr Base.assertCnstr

-- | Get model.
--
-- Reference : <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#gaff310fef80ac8a82d0a51417e073ec0a>
getModel :: MonadZ3 z3 => z3 (Result, Maybe Model)
getModel = liftSolver0 Base.solverCheckAndGetModel Base.getModel

-- | Delete a model object.
--
-- Reference: <http://research.microsoft.com/en-us/um/redmond/projects/z3/group__capi.html#ga0cc98d3ce68047f873e119bccaabdbee>
delModel :: MonadZ3 z3 => Model -> z3 ()
delModel = liftFun1 Base.delModel

withModel :: (Applicative z3, MonadZ3 z3) =>
                (Base.Model -> z3 a) -> z3 (Result, Maybe a)
withModel f = do
 (r,mb_m) <- getModel
 mb_e <- T.traverse f mb_m
 void $ T.traverse delModel mb_m
 return (r, mb_e)

-- | Convert the given model into a string.
showModel :: MonadZ3 z3 => Model -> z3 String
showModel = liftFun1 Base.showModel

-- | Convert Z3's logical context into a string.
showContext :: MonadZ3 z3 => z3 String
showContext = liftScalar Base.showContext

-- | Check whether the given logical context is consistent or not.
check :: MonadZ3 z3 => z3 Result
check = liftSolver0 Base.solverCheck Base.check

---------------------------------------------------------------------
-- String Conversion

-- | Set the mode for converting expressions to strings.
setASTPrintMode :: MonadZ3 z3 => ASTPrintMode -> z3 ()
setASTPrintMode = liftFun1 Base.setASTPrintMode

-- | Convert an AST to a string.
astToString :: MonadZ3 z3 => AST -> z3 String
astToString = liftFun1 Base.astToString

-- | Convert a pattern to a string.
patternToString :: MonadZ3 z3 => Pattern -> z3 String
patternToString = liftFun1 Base.patternToString

-- | Convert a sort to a string.
sortToString :: MonadZ3 z3 => Sort -> z3 String
sortToString = liftFun1 Base.sortToString

-- | Convert a FuncDecl to a string.
funcDeclToString :: MonadZ3 z3 => FuncDecl -> z3 String
funcDeclToString = liftFun1 Base.funcDeclToString

-- | Convert the given benchmark into SMT-LIB formatted string.
--
-- The output format can be configured via 'setASTPrintMode'.
benchmarkToSMTLibString :: MonadZ3 z3 =>
                               String   -- ^ name
                            -> String   -- ^ logic
                            -> String   -- ^ status
                            -> String   -- ^ attributes
                            -> [AST]    -- ^ assumptions1
                            -> AST      -- ^ formula
                            -> z3 String
benchmarkToSMTLibString = liftFun6 Base.benchmarkToSMTLibString
