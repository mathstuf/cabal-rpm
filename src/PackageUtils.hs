-- |
-- Module      :  PackageUtils
-- Copyright   :  (C) 2013-2014  Jens Petersen
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: functions related to Cabal dependency generation.

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

module PackageUtils (
  copyTarball,
  findPkgName,
  findSpecFile,
  isScmDir,
  missingPackages,
  notInstalled,
  packageName,
  packageVersion,
  removePrefix,
  removeSuffix,
  rpmbuild,
  RpmStage (..),
  simplePackageDescription
    ) where

import Dependencies (packageDependencies)
import FileUtils (filesWithExtension, fileWithExtension, fileWithExtension_,
                  getDirectoryContents_, mktempdir)
import Setup (RpmFlags (..))
import SysCmd (cmd, cmd_, shell, systemBool, (+-+))

import Control.Applicative ((<$>))
import Control.Monad    (filterM, liftM, unless, when)

import Data.Char (isAlphaNum)
import Data.List (isSuffixOf, stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Version     (showVersion)

import Distribution.Compiler (CompilerFlavor (..))
import Distribution.Package  (PackageIdentifier (..),
                              PackageName (..))
import Distribution.PackageDescription (PackageDescription (..),
                                        hasExes, hasLibs)
import Distribution.PackageDescription.Configuration (finalizePackageDescription)
import Distribution.PackageDescription.Parse (readPackageDescription)

import Distribution.Simple.Compiler (Compiler (..))
import Distribution.Simple.Configure (configCompiler)
import Distribution.Simple.Program   (defaultProgramConfiguration)
import Distribution.Simple.Utils (die, findPackageDesc)

import Distribution.System (Platform (..), buildArch, buildOS)
import Distribution.Verbosity (Verbosity)

import System.Directory (copyFile, doesDirectoryExist, doesFileExist,
                         getCurrentDirectory, setCurrentDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>), takeBaseName, takeExtension)
import System.Posix.Files (fileMode, getFileStatus, modificationTime,
                           setFileMode)

-- returns path to .cabal file and possibly tmpdir to be removed
findCabalFile :: Verbosity -> FilePath -> IO (FilePath, Maybe FilePath)
findCabalFile vb path = do
  isdir <- doesDirectoryExist path
  if isdir
    then do
      cblfile <- fileWithExtension_ path ".cabal"
      if cblfile
        then do
          file <- findPackageDesc path
          return (file, Nothing)
        else do
          specFile <- fileWithExtension path ".spec"
          maybe (die "Cannot determine package in dir.")
            (cabalFromSpec vb) specFile
    else do
      isfile <- doesFileExist path
      if not isfile
        then if isPackageId path
             then tryUnpack path
             else error $ path ++ ": No such file or directory"
        else if takeExtension path == ".cabal"
             then return (path, Nothing)
             else if takeExtension path == ".spec"
                  then cabalFromSpec vb path
                  else if ".tar.gz" `isSuffixOf` path
                       then do
                         tmpdir <- mktempdir
                         shell $ "tar" +-+ unwords ["zxf", path, "-C", tmpdir, "*.cabal"]
                         subdir <- getDirectoryContents_ tmpdir
                         file <- findPackageDesc $ tmpdir ++ "/" ++ head subdir
                         return (file, Just tmpdir)
                       else error $ path ++ ": file should be a .cabal, .spec or .tar.gz file."
  where
    isPackageId :: String -> Bool
    isPackageId (c:cs) | isAlphaNum c =
      all (\d -> isAlphaNum  d || d `elem` "-." ) cs
    isPackageId _ = False

simplePackageDescription :: FilePath -> RpmFlags
                         -> IO (FilePath, PackageDescription, Maybe FilePath)
simplePackageDescription path opts = do
  let verbose = rpmVerbosity opts
  (cabalPath, mtmp) <- findCabalFile verbose path
  genPkgDesc <- readPackageDescription verbose cabalPath
  (compiler, _) <- configCompiler (Just GHC) Nothing Nothing
                   defaultProgramConfiguration verbose
  case finalizePackageDescription (rpmConfigurationsFlags opts)
       (const True) (Platform buildArch buildOS) (compilerId compiler)
       [] genPkgDesc of
    Left e -> die $ "finalize failed: " ++ show e
    Right (pd, _) -> return (cabalPath, pd, mtmp)

cabalFromSpec :: Verbosity -> FilePath -> IO (FilePath, Maybe FilePath)
cabalFromSpec vrb specFile = do
  -- no rpmspec command in RHEL 5 and 6
  namever <- removePrefix "ghc-" . head . lines <$> cmd "rpm" ["-q", "--qf", "%{name}-%{version}\n", "--specfile", specFile]
  fExists <- doesFileExist $ namever ++ ".tar.gz"
  unless fExists $
    let (n, v) = nameVersion namever in
    copyTarball n v False
  dExists <- doesDirectoryExist namever
  if dExists
    then do
    specTime <- modificationTime <$> getFileStatus specFile
    dirTime <- modificationTime <$> getFileStatus namever
    when (specTime > dirTime) $ rpmbuild Prep specFile
    else rpmbuild Prep specFile
  findCabalFile vrb namever

nameVersion :: String -> (String, String)
nameVersion nv =
  if '-' `notElem` nv
    then error $ "nameVersion: malformed NAME-VER string" +-+ nv
    else (reverse eman, reverse rev)
  where
    (rev, '-':eman) = break (== '-') $ reverse nv

data RpmStage = Binary | Source | Prep | BuildDep deriving Eq

rpmbuild :: RpmStage -> FilePath -> IO ()
rpmbuild mode spec = do
  let rpmCmd = case mode of
        Binary -> "a"
        Source -> "s"
        Prep -> "p"
        BuildDep -> "_"
  cwd <- getCurrentDirectory
  cmd_ "rpmbuild" $ ["-b" ++ rpmCmd] ++
    ["--nodeps" | mode == Prep] ++
    ["--define=_rpmdir" +-+ cwd,
     "--define=_srcrpmdir" +-+ cwd,
     "--define=_sourcedir" +-+ cwd,
     spec]

removePrefix :: String -> String-> String
removePrefix pref str = fromMaybe str (stripPrefix pref str)

removeSuffix :: String -> String -> String
removeSuffix suffix orig =
  fromMaybe orig $ stripSuffix suffix orig
  where
    stripSuffix sf str = reverse <$> stripPrefix (reverse sf) (reverse str)

tryUnpack :: String -> IO (FilePath, Maybe FilePath)
tryUnpack pkg = do
  pkgver <- if '.' `elem` pkg then return pkg
            else do
              contains_pkg <- lines <$> cmd "cabal" ["list", "--simple-output", pkg]
              let pkgs = filter ((== pkg) . takeWhile (not . (== ' '))) contains_pkg
              if null pkgs
                then error $ pkg ++ " hackage not found"
                else return $ map (\c -> if c == ' ' then '-' else c) $ last pkgs
  isdir <- doesDirectoryExist pkgver
  if isdir
    then do
    pth <- findPackageDesc pkgver
    return (pth, Nothing)
    else do
    cwd <- getCurrentDirectory
    tmpdir <- mktempdir
    setCurrentDirectory tmpdir
    cmd_ "cabal" ["unpack", "-v0", pkgver]
    pth <- findPackageDesc pkgver
    setCurrentDirectory cwd
    return (tmpdir ++ "/" ++ pth, Just tmpdir)

packageName :: PackageIdentifier -> String
packageName pkg = name
  where PackageName name = pkgName pkg

packageVersion :: PackageIdentifier -> String
packageVersion = showVersion . pkgVersion

(<||>) :: IO Bool -> IO Bool -> IO Bool
(<||>) f s = do
  one <- f
  if one then return True else s

isScmDir :: FilePath -> IO Bool
isScmDir dir =
  doesDirectoryExist (dir </> ".git") <||> doesDirectoryExist (dir </> "_darcs")

notInstalled :: String -> IO Bool
notInstalled br =
  liftM not $ systemBool $ "rpm -q --whatprovides" +-+ shellQuote br
  where
    shellQuote :: String -> String
    shellQuote (c:cs) = (if c `elem` "()" then (['\\', c] ++) else (c:)) (shellQuote cs)
    shellQuote "" = ""

missingPackages :: PackageDescription -> String -> IO [String]
missingPackages pkgDesc name = do
  (deps, tools, clibs, pkgcfgs, _) <- packageDependencies pkgDesc name
  filterM notInstalled $ deps ++ ["ghc-Cabal-devel", "ghc-rpm-macros"] ++ tools ++ clibs ++ pkgcfgs

findPkgName :: PackageDescription -> RpmFlags -> IO String
findPkgName pkgDesc flags = do
  let name = packageName $ package pkgDesc
      forceLib = hasLib && rpmLibrary flags
      hasExec = hasExes pkgDesc
      hasLib = hasLibs pkgDesc
      possNames = ["ghc-" ++ name | hasLib] ++
                  [name | hasExec && not (hasLib && rpmLibrary flags)]
  pkgs <- filter (`elem` possNames) . map takeBaseName <$> filesWithExtension "." ".spec"
  case pkgs of
    [one] -> return one
    _ -> return (if hasExec && not forceLib then name else "ghc-" ++ name)

findSpecFile :: PackageDescription -> RpmFlags -> IO (FilePath, Bool)
findSpecFile pkgDesc flags = do
  pkgname <- findPkgName pkgDesc flags
  let specfile = pkgname ++ ".spec"
  exists <- doesFileExist specfile
  return (specfile, exists)

copyTarball :: String -> String -> Bool -> IO ()
copyTarball n v ranFetch = do
  let tarfile = n ++ "-" ++ v ++ ".tar.gz"
  already <- doesFileExist tarfile
  unless already $ do
    home <- getEnv "HOME"
    let cacheparent = home </> ".cabal" </> "packages"
        tarpath = n </> v </> tarfile
    remotes <- getDirectoryContents_ cacheparent
    let paths = map (\ repo -> cacheparent </> repo </> tarpath) remotes
    -- if more than one tarball, should maybe warn if they are different
    tarballs <- filterM doesFileExist paths
    if null tarballs
      then if ranFetch
           then error $ "No" +-+ tarfile +-+ "found"
           else do
             cmd_ "cabal" ["fetch", "-v0", "--no-dependencies", n ++ "-" ++ v]
             copyTarball n v True
      else do
        copyFile (head tarballs) tarfile
        -- cabal fetch creates tarballs with mode 0600
        stat <- getFileStatus tarfile
        when (fileMode stat /= 0o100644) $
          setFileMode tarfile 0o0644
