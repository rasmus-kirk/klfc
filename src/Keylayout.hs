{-# LANGUAGE UnicodeSyntax, NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE FlexibleContexts #-}

module Keylayout
    ( KeylayoutConfig(..)
    , printKeylayout
    , toKeylayout
    ) where

import BasePrelude
import Prelude.Unicode hiding ((∈))
import Data.Foldable.Unicode ((∈))
import Data.Monoid.Unicode ((∅), (⊕))
import Data.List.Unicode ((∖))
import Util (show', (>$>), groupSortWith, tellMaybeT, versionStr, concatMapM)
import qualified WithPlus as WP (singleton)

import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Writer (tell)
import qualified Data.ByteString.Lazy as BL (ByteString)
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text.Lazy as L (Text, pack, replace)
import qualified Data.Text.Lazy.Encoding as L (encodeUtf8)
import Lens.Micro.Platform (view, set, over, _1, _2)
import Text.XML.Light

import Layout.DeadKey (getModifiedLetters)
import Layout.Key (filterKeyOnShiftstatesM, addCapslock, letterToDeadKey, presetDeadKeyToDeadKey, addPresetDeadToDead, baseCharToChar)
import Layout.Layout
import qualified Layout.Modifier as M
import Layout.Types
import Lookup.MacOS
import PresetLayout (defaultKeys, defaultFullLayout, defaultMacKeys)

data KeylayoutConfig = KeylayoutConfig
    { __addShortcuts ∷ Bool
    }

prepareLayout ∷ Logger m ⇒ KeylayoutConfig → Layout → m Layout
prepareLayout KeylayoutConfig{__addShortcuts = addShortcuts} =
    over (_keys ∘ traverse) (bool id addShortcutLetters addShortcuts) >>>
    addSingletonKeysAsKeys >>>
    addDefaultKeysWith const defaultMacKeys >>>
    addDefaultKeys defaultKeys >>>
    (_keys ∘ traverse)
        (filterKeyOnShiftstatesM supportedShiftstate >$>
        addCapslock >>>
        over (_letters ∘ traverse) addPresetDeadToDead)

supportedShiftstate ∷ Logger m ⇒ Shiftstate → m Bool
supportedShiftstate = fmap and ∘ traverse supportedModifier ∘ toList

supportedModifier ∷ Logger m ⇒ Modifier → m Bool
supportedModifier modifier
  | modifier ∈ map fst modifierAndString = pure True
  | otherwise = False <$ tell [show' modifier ⊕ " is not supported in keylayout"]

addShortcutLetters ∷ Key → Key
addShortcutLetters key | any (WP.singleton M.Win ∈) (view _shiftlevels key) = key
addShortcutLetters key = fromMaybe key $
    over _shiftlevels (M.singleton M.Win :) <$>
    _letters (liftA2 (:) (getLetterByPosAndShiftstate shortcutPos (∅) defaultLayout) ∘ pure) key
  where
    shortcutPos = view _shortcutPos key
    defaultLayout = defaultFullLayout ⊕ set _keys defaultMacKeys (∅)

attr ∷ String → String → Attr
attr = Attr ∘ unqual

printKeylayout ∷ Element → BL.ByteString
printKeylayout = L.encodeUtf8 ∘ xmlEntitiesToNumeric ∘ L.pack ∘ (header ⊕) ∘ (⊕ "\n") ∘ ppElement
  where
    header = unlines
        [ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        , "<!DOCTYPE keyboard SYSTEM \"file://localhost/System/Library/DTDs/KeyboardLayout.dtd\">"
        , "<!--"
        , "  Generated by KLFC " ⊕ versionStr
        , "  https://github.com/39aldo39/klfc"
        , "-->"
        ]

xmlEntitiesToNumeric ∷ L.Text → L.Text
xmlEntitiesToNumeric =
    L.replace "&quot;" "&#34;" >>>
    L.replace "&amp;"  "&#38;" >>>
    L.replace "&apos;" "&#39;" >>>
    L.replace "&lt;"   "&#60;" >>>
    L.replace "&gt;"   "&#62;"

toKeylayout ∷ Logger m ⇒ KeylayoutConfig → Layout → m Element
toKeylayout config = prepareLayout config >=> toKeylayout'

toKeylayout' ∷ Logger m ⇒ Layout → m Element
toKeylayout' layout =
    removeEmptyElementsInside ∘ unode "keyboard" ∘ (,)
        [ attr "group" "126"
        , attr "id" "-1337"
        , attr "name" (view (_info ∘ _fullName) layout)
        ] <$> sequence
        [ pure $ unode "layouts" layoutElement
        , pure $ toModifierMap shiftlevels
        , keyMapSetElementOutputToActions modifiedStrings <$> toKeyMapSet keys
        , unode "actions" ∘ (map deadKeyToAction deadKeys ⧺) <$> deadKeysToActions deadKeys
        , pure $ unode "terminators" (mapMaybe deadKeyToTerminator deadKeys)
        ]
  where
    (keys, shiftlevels) = unifyShiftlevels (view _keys layout)
    modifiedStrings = S.unions (map (S.map letterToString ∘ getModifiedLetters) deadKeys)
    letterToString (Char c) = [c]
    letterToString (Ligature _ s) = s
    letterToString _ = ""
    deadKeys = nub (concatMap (mapMaybe letterToDeadKey ∘ view _letters) keys)
    deadKeysToActions =
        concatMapM chainedDeadKeyToActions >$>
        groupSortWith fst >>>
        over (traverse ∘ _2 ∘ traverse) snd >>>
        map (\(s, elms) → (s, emptyAction s : elms)) >>>
        map (unode "action" ∘ over _1 ((:[]) ∘ attr "id"))
    emptyAction s = unode "when" [attr "state" "none", attr "output" s]
    layoutElement = unode "layout"
        [ attr "first" "0"
        , attr "last" "0"
        , attr "modifiers" "defaultModifierMap"
        , attr "mapSet" "defaultKeyMapSet"
        ]

removeEmptyElementsInside ∷ Element → Element
removeEmptyElementsInside e = e { elContent = mapMaybe removeEmptyElements' (elContent e) }

removeEmptyElements ∷ Element → Maybe Element
removeEmptyElements e
  | null (elAttribs e) ∧ null (elContent e) ∧ null (elLine e) = Nothing
  | otherwise = Just e

removeEmptyElements' ∷ Content → Maybe Content
removeEmptyElements' (Elem e) = Elem ∘ removeEmptyElementsInside <$> removeEmptyElements e
removeEmptyElements' c = Just c

toModifierMap ∷ [Shiftlevel] → Element
toModifierMap states = unode "modifierMap" ∘ (,)
    [ attr "id" "defaultModifierMap"
    , attr "defaultIndex" "0"
    ] ∘
    zipWith toKeyMapSelect [0..] $ map (toModifiers ignored) states
  where
    ignored = ($ states) $
        concatMap (concatMap (concatMap usedModifiers)) >>>
        (map fst modifierAndString ∖) >>>
        removeDoubleModifiers >>>
        mapMaybe (`lookup` modifierAndString) >>>
        map (⊕ "?")

toKeyMapSelect ∷ Int → [Element] → Element
toKeyMapSelect i = unode "keyMapSelect" ∘ (,) [attr "mapIndex" (show i)]

toModifiers ∷ [String] → Shiftlevel → [Element]
toModifiers ignored =
    map (map modifierToString ∘ toList) ∘ toList >$>
    unode "modifier" ∘ (:[]) ∘ attr "keys" ∘ unwords ∘ (⧺ ignored)

modifierToString ∷ Modifier → String
modifierToString modifier = fromMaybe e (lookup modifier modifierAndString)
  where e = error $ show' modifier ⊕ " is not supported in keylayout"

toKeyMapSet ∷ Logger m ⇒ [Key] → m Element
toKeyMapSet =
    transpose ∘ map (\key → (,) (view _pos key) <$> view _letters key) >>>
    zipWithM toKeyMap [0..] >$>
    unode "keyMapSet" ∘ (,) [attr "id" "defaultKeyMapSet"]

toKeyMap ∷ Logger m ⇒ Int → [(Pos, Letter)] → m Element
toKeyMap i =
    traverse (uncurry printKey) >$>
    catMaybes >>>
    unode "keyMap" ∘ (,) [attr "index" (show i)]

printKey ∷ Logger m ⇒ Pos → Letter → m (Maybe Element)
printKey pos letter = runMaybeT $
    unode "key" <$> sequence
      [ attr "code" <$> printPos pos
      , printLetter letter
      ]

printPos ∷ Logger m ⇒ Pos → MaybeT m String
printPos pos = maybe e (pure ∘ show) (lookup pos posAndCode)
  where e = tellMaybeT [show' pos ⊕ " is not supported in keylayout"]

printLetter ∷ Logger m ⇒ Letter → MaybeT m Attr
printLetter (Char c) = pure (attr "output" [c])
printLetter (Ligature _ s) = pure (attr "output" s)
printLetter (Dead dead) = printLetter (CustomDead Nothing (presetDeadKeyToDeadKey dead))
printLetter (CustomDead _ (DeadKey name _ _)) = pure (attr "action" ("dead:" ⊕ name))
printLetter (Action a) | Just c ← lookup a actionAndChar = pure (attr "output" [c])
printLetter LNothing = MaybeT (pure Nothing)
printLetter letter = tellMaybeT [show' letter ⊕ " is not supported in keylayout"]

deadKeyToAction ∷ DeadKey → Element
deadKeyToAction (DeadKey name _ _) =
    unode "action" ([attr "id" name'], unode "when" [attr "state" "none", attr "next" name'])
  where name' = "dead:" ⊕ name

chainedDeadKeyToActions ∷ Logger m ⇒ DeadKey → m [(String, Element)]
chainedDeadKeyToActions (DeadKey name _ actionMap) =
    concatMapM (actionToActions name) actionMap

actionToActions ∷ Logger m ⇒ String → (Letter, ActionResult) → m [(String, Element)]
actionToActions name (Char c, OutString s) = pure
    [([c], unode "when" [attr "state" ("dead:" ⊕ name), attr "output" s])]
actionToActions name (Char c, Next (DeadKey cName _ actionMap)) = do
    next ← concatMapM (actionToActions cName) actionMap
    pure $
      ([c], unode "when" [attr "state" ("dead:" ⊕ name), attr "next" ("dead:" ⊕ cName)]) :
      next
actionToActions _ (l, _) = [] <$ tell [show' l ⊕ " as letter for a dead key is not supported in keylayout"]

deadKeyToTerminator ∷ DeadKey → Maybe Element
deadKeyToTerminator (DeadKey name baseChar _)
  | Just c ← baseCharToChar baseChar
  = Just (unode "when" [attr "state" ("dead:" ⊕ name), attr "output" [c]])
deadKeyToTerminator _ = Nothing

keyMapSetElementOutputToActions ∷ Set String → Element → Element
keyMapSetElementOutputToActions =
    overElements ∘ overElements ∘ keyElementOutputToAction
  where
    overElements f elm = elm { elContent = map (overContent f) (elContent elm) }
    overContent f (Elem e) = Elem (f e)
    overContent _ x = x

keyElementOutputToAction ∷ Set String → Element → Element
keyElementOutputToAction modifiedStrings elm = elm { elAttribs = map outputToAction (elAttribs elm) }
  where
    outputToAction a
      | attrKey a ≡ unqual "output"
      ∧ attrVal a ∈ modifiedStrings
      = a { attrKey = unqual "action", attrVal = prependLig (attrVal a) }
      | otherwise = a

prependLig ∷ String → String
prependLig "" = ""
prependLig [x] = [x]
prependLig s = "lig:" ⊕ s
