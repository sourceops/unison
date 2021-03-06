{-# LANGUAGE OverloadedStrings #-}

module Main where

import Text.Printf (printf)
import Control.Applicative
import Control.Monad
import Data.List
import Data.Maybe
import Data.Tuple (swap)
import System.Environment (getArgs)
import System.IO
import Unison.Codebase (Codebase)
import Unison.Codebase.Store (Store)
import Unison.Hash.Extra ()
import Unison.Note (Noted)
import Unison.Reference (Reference)
import Unison.Runtime.Address
import Unison.Symbol (Symbol)
import Unison.Symbol.Extra ()
import Unison.Term (Term)
import Unison.Term.Extra ()
import Unison.Type (Type)
import Unison.Var (Var)
import qualified Crypto.Random as Random
import qualified Data.ByteString.Base58 as Base58
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified System.Directory as Directory
import qualified System.Process as Process
import qualified Unison.ABT as ABT
import qualified Unison.BlockStore.FileBlockStore as FBS
import qualified Unison.Builtin as Builtin
import qualified Unison.Codebase as Codebase
import qualified Unison.Codebase.FileStore as FileStore
import qualified Unison.Cryptography as C
import qualified Unison.Doc as Doc
import qualified Unison.Hash as Hash
import qualified Unison.Metadata as Metadata
import qualified Unison.Note as Note
import qualified Unison.Parser as Parser
import qualified Unison.Parsers as Parsers
import qualified Unison.Paths as Paths
import qualified Unison.Reference as Reference
import qualified Unison.Runtime.ExtraBuiltins as EB
import qualified Unison.Symbol as Symbol
import qualified Unison.Term as Term
import qualified Unison.TermParser as TermParser
import qualified Unison.TypeParser as TypeParser
import qualified Unison.Util.Logger as L
import qualified Unison.Var as Var
import qualified Unison.View as View
import qualified Unison.Views as Views

type V = Symbol View.DFO

{-
unison new
unison add [<name>]
unison edit name
unison view name
unison rename src target
unison statistics [name]
unison help
unison eval [name]
-}

randomBase58 :: Int -> IO String
randomBase58 numBytes = do
  bytes <- Random.getRandomBytes numBytes
  let base58 = Base58.encodeBase58 Base58.bitcoinAlphabet bytes
  pure (Text.unpack $ Text.decodeUtf8 base58)

readLineTrimmed :: IO String
readLineTrimmed = Text.unpack . Text.strip . Text.pack <$> getLine

viewResult :: Codebase IO V Reference (Type V) (Term V)
           -> Codebase.SearchResults V Reference (Term V)
           -> Term V
           -> Noted IO String
viewResult code _ (Term.Ref' r) = Codebase.viewAsBinding code r
viewResult code rs e = pure (Doc.formatText80 (Views.termMd (Map.fromList $ Codebase.references rs) e))

maxSearchResults = 100

search :: Codebase IO V Reference (Type V) (Term V) -> String -> IO (Codebase.SearchResults V Reference (Term V))
search code query = case Parsers.unsafeParseTerm query of
  Term.Blank' ->
    Note.run $ Codebase.search code Term.blank [] maxSearchResults (Metadata.Query "") Nothing
  Term.Ann' Term.Blank' t ->
    Note.run $ Codebase.search code (Term.blank `Term.ann` t) [Paths.Body] maxSearchResults (Metadata.Query "") Nothing
  Term.Ann' (Term.Var' v) t ->
    Note.run $ Codebase.search code (Term.blank `Term.ann` t) [Paths.Body] maxSearchResults (Metadata.Query $ Var.name v) Nothing
  Term.Var' v ->
    Note.run $ Codebase.search code Term.blank [] maxSearchResults (Metadata.Query $ Var.name v) Nothing
  _ -> fail "FAILED search syntax invalid, must be `<name>` or `<name> : <type>`"

formatSearchResults :: Codebase IO V Reference (Type V) (Term V)
                    -> Codebase.SearchResults V Reference (Term V) -> IO ()
formatSearchResults code rs = mapM_ fmt (fst . Codebase.matches $ rs) where
  fmt e = putStrLn =<< Note.run (viewResult code rs e)

pickExactMatch :: Codebase IO V Reference (Type V) (Term V)
               -> String
               -> Codebase.SearchResults V Reference (Term V)
               -> IO (Maybe (Term V))
pickExactMatch code name rs = case fst (Codebase.matches rs) of
  [] -> pure Nothing
  [x] -> pure (Just x)
  es -> do
    names <- Map.fromList . map swap . Map.toList <$> Note.run (Codebase.firstNames code [ r | Term.Ref' r <- es ])
    pure $ do
      r <- Map.lookup (Var.named (Text.pack name)) names
      listToMaybe [ e | e@(Term.Ref' r') <- es, r' == r ]

pickSearchResult :: Codebase IO V Reference (Type V) (Term V)
                 -> String -> Codebase.SearchResults V Reference (Term V) -> IO (Maybe (Term V))
pickSearchResult code name rs = pickExactMatch code name rs >>= \o -> case o of
  Just e -> pure (Just e)
  Nothing | null (fst (Codebase.matches rs)) -> pure Nothing
  Nothing -> do
    let es = fst (Codebase.matches rs)
    putStrLn "Multiple search results, choose one:\n"
    let fmt (e, n) = do
          putStrLn $ show n ++ "."
          putStrLn =<< Note.run (viewResult code rs e)
    mapM_ fmt (es `zip` [(1::Int) ..])
    putStr "> "; hFlush stdout
    choice <- readLineTrimmed
    case choice of
      "" -> pure Nothing
      choice -> pure $ listToMaybe $ drop (read choice - 1) es

tryEdits :: [FilePath] -> IO ()
tryEdits paths = do
  editorCommand <- (Text.unpack . Text.strip . Text.pack <$> readFile ".editor") <|> pure ""
  case editorCommand of
    "" -> do putStrLn "  TIP: Create a file named .editor with the command to launch your"
             putStrLn "       editor and `unison new` and `unison edit` will invoke it on newly created files"
    _ -> forM_ paths $ \path -> let cmd = editorCommand ++ " " ++ path
                                in do putStrLn cmd; Process.callCommand cmd

refsOnly results =
  results { Codebase.matches = tweak (Codebase.matches results) }
  where
  tweak (es, rem) = ([ Term.ref r | Term.Ref' r <- es ], rem)

process :: IO (Codebase IO V Reference (Type V) (Term V)) -> [String] -> IO ()
process _ [] = putStrLn $ intercalate "\n"
  [ "usage: unison <subcommand> [<args>]"
  , ""
  , "subcommands: "
  , "  unison new"
  , "  unison add [<name>]"
  , "  unison edit <name>"
  , "  unison view <name>"
  , "  unison rename <name-src> [<name-target>]"
  , "  unison statistics [<name>]"
  , "  unison help [{new, add, edit, view, rename, statistics}]" ]
process codebase ["help"] = process codebase []
process codebase ("help" : sub) = case sub of
  ["new"] -> putStrLn "Creates a new set of scratch files (for new definitions)"
  ["add"] -> putStrLn "Add definitions in scratch files to codebase"
  ["edit"] -> putStrLn "Opens a definition for editing"
  ["view"] -> putStrLn "Views the current source of a definition"
  ["rename"] -> do
    putStrLn "Renames a definition (with args)"
    putStrLn "or appends first few characters of hash to the name (no args)"
  ["statistics"] -> do
    putStrLn "Gets statistics about a definition (with args)"
    putStrLn "or about all open edits (no args)"
  ["help"] -> putStrLn "prints this message"
  _ -> do putStrLn $ intercalate " " sub ++ " is not a subcommand"
          process codebase []
process _ ["new"] = do
  name <- randomBase58 10
  writeFile (name ++ ".u") ("-- add your definition(s) here, then do\n--  unison add " ++ name ++ ".u")
  let mdpath = name ++ ".markdown"
  writeFile mdpath ""
  putStrLn $ "Created " ++ name ++ ".{u, markdown} for code and docs"
  tryEdits [name ++ ".u"]
process codebase ("view" : rest) = do
  codebase <- codebase
  let query = intercalate " " rest
  results <- search codebase query
  exact <- pickExactMatch codebase query results
  case exact of
    Just e -> putStrLn =<< Note.run (viewResult codebase results e)
    Nothing -> formatSearchResults codebase (refsOnly results)
process codebase ("rename" : src : target) = do
  codebase <- codebase
  results <- search codebase src
  r <- pickSearchResult codebase src (refsOnly results)
  case r of
    Just (Term.Ref' r) -> do
      [md] <- Map.elems <$> Note.run (Codebase.metadatas codebase [r])
      let suffix = "#" ++ show r
          md' = if null target then Metadata.mangle (Text.pack suffix) md
                else md { Metadata.names = Metadata.Names (map rename (Metadata.allNames (Metadata.names md))) }
          rename n | Text.pack src `Text.isPrefixOf` Var.name n = Var.named (Text.pack $ intercalate " " target)
                   | otherwise = n
      Note.run $ Codebase.updateMetadata codebase r md'
      putStrLn $ if null target then "OK appended " ++ suffix ++ " onto name(s)"
                                else "OK"
    _ -> putStrLn $ "FAILED could not find a definition for renaming"
process codebase ("edit" : rest) = do
  codebase <- codebase
  let query = intercalate " " rest
  results <- search codebase query
  r <- pickSearchResult codebase query (refsOnly results)
  case r of
    Just (Term.Ref' r@(Reference.Derived h)) -> do
      files <- Directory.getDirectoryContents "."
      let parentFiles = filter (".parent" `Text.isSuffixOf`) (map Text.pack files)
          hashrs = Text.unpack (Hash.base64 h)
      parentMatches <- map (== hashrs) <$> mapM readFile (map Text.unpack parentFiles)
      case listToMaybe [ f | (f, True) <- parentFiles `zip` parentMatches ] of
        Just name -> do
          putStrLn "Definition is already open for editing, launching editor ..."
          tryEdits [stripExtension (Text.unpack name) ++ ".u"]
        Nothing -> do
          s <- Note.run $ Codebase.viewAsBinding codebase r
          name <- randomBase58 10
          writeFile (name ++ ".u") s
          writeFile (name ++ ".parent") (Text.unpack $ Hash.base64 h)
          let mdpath = name ++ ".markdown"
          writeFile mdpath ""
          tryEdits [name ++ ".u"]
    _ -> putStrLn "FAILED could not find definition for editing"
process codebase ("add" : []) = do
  files <- Directory.getDirectoryContents "."
  let ufiles = filter (".u" `Text.isSuffixOf`) (map Text.pack files)
  case ufiles of
    [] -> putStrLn "No .u files in current directory"
    [name] -> process codebase ("add" : [Text.unpack name])
    _ -> do
      putStrLn "Multiple .u files in current directory"
      putStr "  "
      putStrLn . Text.unpack . Text.intercalate "\n  " $ ufiles
      putStrLn "Supply one of these files as the argument to `unison add`"
process codebase ("statistics" : []) = do
  files <- Directory.getDirectoryContents "."
  let parentFiles = map Text.unpack $ filter (".parent" `Text.isSuffixOf`) (map Text.pack files)
  refs <- mapM readFile parentFiles
  refs <- pure (map (Reference.Derived . Hash.fromBase64 . Text.pack) refs)
  codebase <- codebase
  scores <- Note.run $ Codebase.statistics codebase refs
  mds <- Note.run $ Codebase.metadatas codebase refs
  when (not (null mds)) $ do
    putStrLn "For each open definition, count the set of transitive dependents."
    putStrLn "If N definitions have a common dependent, the contribution of that"
    putStrLn "dependent to score is divided by N.\n"
    putStrLn "TIP: Update definitions with higher scores first.\n"
    printf "  %-10s %s\n" ("Score" :: String) ("Name" :: String)
  mapM_ (fmt mds) (Map.toList scores)
  case null mds of
    True -> putStrLn "No open edits. Use `unison edit` to begin a refactoring."
    False -> printf "\n  %-10.2f (total remaining)\n" (sum $ Map.elems scores)
  where
  print name score = printf "  %-10.2f %s\n" score name
  fmt mds (ref, score) = case Map.lookup ref mds of
    Nothing -> print (show ref) score
    Just md -> case Metadata.firstName (Metadata.names md) of
      Just v -> print (show v) score
      Nothing -> print (show ref) score
process codebase ("statistics" : stuff) = putStrLn "Not implemented yet"
process codebase ("add" : [name]) = go0 name where
  baseName = stripu name
  go0 name = do
    codebase <- codebase
    str <- readFile name
    hasParent <- Directory.doesFileExist (baseName `mappend` ".parent")
    bs <- case Parser.run TermParser.moduleBindings str TypeParser.s0 of
      Parser.Fail err _ -> putStrLn ("FAILED parsing " ++ name) >> mapM_ putStrLn err >> fail "parse failure"
      Parser.Succeed bs _ _ -> bs <$ putStrLn ("OK parsed " ++ name ++ ", processing declarations ...\n")
    go codebase name hasParent bs
  go codebase name hasParent bs = do
    let hooks' = Codebase.Hooks startingToProcess nameShadowing duplicateDefinition renamedOldDefinition ambiguousReferences finishedDeclaring
        startingToProcess (v, _) = putStrLn ("  " ++ show v) >> putStrLn ("  " ++ replicate (length (show v)) '-')
        nameShadowing [] (_, _) = do
          putStrLn "  OK name of this binding does not collide with existing definitions"
          pure Codebase.FailIfShadowed
        nameShadowing _ (_, _) | hasParent = pure Codebase.RenameOldIfShadowed
        nameShadowing tms (v, _) = do
          putStrLn $ "  WARN name collides with existing definition(s):"
          putStrLn $ "\n" ++ (unlines $ map (("    " ++) . show) tms)
          putStrLn $ unlines
            [ "  You can:", ""
            , "    1) `rename` - append first few characters of hash to old name"
            , "    2) `allow` the ambiguity - uses of this name will need to disambiguate via hash"
            , "    3) `cancel` or <Enter> - exit without making changes" ]
          putStr "  > "; hFlush stdout
          line <- readLineTrimmed
          case line of
            _ | line == "rename" || line == "1" -> pure Codebase.RenameOldIfShadowed
              | line == "allow" || line == "2" -> pure Codebase.AllowShadowed
              | otherwise -> pure Codebase.FailIfShadowed
        duplicateDefinition old (v, new) = do
          putStrLn "  YUREKA! you've rediscovered an existing definition, with the form:\n"
          form <- Note.run $ Codebase.viewAsBinding codebase old
          let indent s = "    " ++ (s >>= \ch -> if ch == '\n' then "\n    " else [ch])
          putStrLn (indent form)
          putStrLn "  <Enter> (use existing form) or `r` (replace with newer form)"
          putStr "  > "; hFlush stdout
          line <- Text.strip . Text.pack <$> getLine
          case line of
            "" -> pure False
            _ -> pure True
        renamedOldDefinition v v' = putStrLn $ "  OK renamed old " ++ show v ++ " to " ++ show v'
        ambiguousReferences vs v = do
          putStrLn "  FAILED ambiguous or unresolved references in body of binding\n"
          forM_ vs $ \(v, tms) -> case tms of
            [] -> putStrLn $ "  " ++ show v ++ " could not be resolved"
            tms -> putStrLn $ "  " ++ show v ++ " could refer to any of " ++ intercalate "  " (map show tms)
          putStrLn "\n\n  Use syntax foo#8adj3 to pick a version of 'foo' by hash prefix #8adj3"
        finishedDeclaring (v, _) h = do
          putStrLn $ "  OK finished declaring, definition has hash: " ++ show h
    results <- Note.run $ Codebase.declareCheckAmbiguous hooks' bs codebase
    case results of
      Right declared -> do
        Directory.removeFile (baseName `mappend` ".markdown") <|> pure ()
        Directory.removeFile (baseName `mappend` ".u") <|> pure ()
        let parentFile = baseName `mappend` ".parent"
        parent <- readFile parentFile <|> pure ""
        hasParent <- (True <$ Directory.removeFile parentFile) <|> pure False
        let suffix = if hasParent then ".{u, markdown, parent}" else ".{u, markdown}"
        putStrLn $ "\nOK removed files " ++ baseName ++ suffix
        case hasParent of
          False -> pure ()
          True -> do
            let pr = Reference.Derived (Hash.fromBase64 (Text.pack parent))
            Just v <- Note.run $ Codebase.firstName codebase pr
            dependents <- Note.run $ Codebase.dependents codebase Nothing pr
            prevType <- Note.run $ Codebase.typeAt codebase (Term.ref pr) []
            let declared' = if length declared == 1 then declared
                            else filter (\(v',_) -> v == v') declared
                edits deps = mapM_ go [ h | Reference.Derived h <- deps ]
                go h = process (pure codebase) ["edit", Text.unpack $ Hash.base64 h ]
            when (Set.size dependents > 0) $ case declared' of
              [] -> putStrLn "OK scratch file contained no declarations"
              (v, r) : _ -> do
                updatedType <- Note.run $ Codebase.typeAt codebase (Term.ref r) []
                case updatedType == prevType of
                  False -> do
                    putStrLn "\nThis edit was not type-preserving, you can:\n"
                    putStrLn "  1) Do nothing"
                    putStrLn "  2) Open direct dependents for editing\n"
                    putStrLn "> "; hFlush stdout
                    line <- readLineTrimmed
                    case line of
                      "1" -> pure ()
                      "2" -> edits (Set.toList dependents)
                      _ -> pure ()
                  True -> do
                    putStrLn "\nThis edit was type-preserving, you can:\n"
                    putStrLn "  1) Do nothing"
                    putStrLn "  2) Open direct dependents for editing"
                    putStrLn "  3) Propagate to all transitive dependents\n"
                    putStr "> "; hFlush stdout
                    line <- readLineTrimmed
                    case line of
                      "1" -> pure ()
                      "2" -> edits (Set.toList dependents)
                      _ | line == "" || line == "3" -> do
                        replaced <- Note.run $ Codebase.replace codebase pr r
                        putStrLn $ "OK updated " ++ show (Map.size replaced) ++ " definitions"
                      _ -> pure ()
      Left _ -> pure ()

process codebase _ = process codebase []

stripExtension :: String -> String
stripExtension s = case dropWhile (/= '.') (reverse s) of
  [] -> s
  s -> reverse (drop 1 s)

stripu :: String -> String
stripu s | Text.isSuffixOf ".u" (Text.pack s) = reverse . drop 2 . reverse $ s
stripu s = s

hash :: Var v => Term.Term v -> Reference
hash (Term.Ref' r) = r
hash t = Reference.Derived (ABT.hash t)

store :: IO (Store IO (Symbol.Symbol View.DFO))
store = FileStore.make "codebase"

makeRandomAddress :: C.Cryptography k syk sk skp s h c -> IO Address
makeRandomAddress crypt = Address <$> C.randomBytes crypt 64

main :: IO ()
main = getArgs >>= process codebase
  where
  codebase = do
    mapM_ (`hSetEncoding` utf8) [stdout, stdin, stderr]
    store' <- store
    logger <- L.atomic (L.atInfo L.toStandardError)
    let crypto = C.noop "dummypublickey"
    blockStore <- FBS.make' (makeRandomAddress crypto) makeAddress "blockstore"
    builtins0 <- pure $ Builtin.make logger
    builtins1 <- EB.make logger blockStore crypto
    codebase <- pure $ Codebase.make hash store'
    Codebase.addBuiltins (builtins0 ++ builtins1) store' codebase
    pure codebase
