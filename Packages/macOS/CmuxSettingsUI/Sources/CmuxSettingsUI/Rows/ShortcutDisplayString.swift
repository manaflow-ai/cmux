import CmuxSettings
import SwiftUI

private let shortcutFormatter = ShortcutDisplayFormatter()

/// Formats a ``StoredShortcut`` for display in the keyboard-shortcuts
/// settings UI, mirroring the legacy app-target `displayedShortcutString`
/// so the package recorder is visually identical to the historical control.
///
/// When `numbered` is `true` the binding represents the whole `1…9` digit
/// family (see ``ShortcutAction/usesNumberedDigitMatching``): the key glyph
/// is replaced with the range `1…9` so the row reads `⌃1…9` instead of the
/// literal single digit `⌃1`. Pass `ShortcutAction.usesNumberedDigitMatching`
/// for the action whose binding is being rendered.
///
/// ```swift
/// shortcutDisplayString(StoredShortcut(first: .init(key: "1", control: true)), numbered: true)
/// // "⌃1…9"
/// ```
func shortcutDisplayString(_ shortcut: StoredShortcut, numbered: Bool) -> String {
    shortcutFormatter.displayString(shortcut, numbered: numbered)
}

/// The `1…9` range glyph shown for numbered-digit bindings. A
/// language-neutral numeric range, so it is not localized — matching the
/// `"1…9"` literal baked into the numbered actions' display names.
let numberedDigitRangeHint = shortcutFormatter.numberedDigitRangeHint

/// Whether `key` is a single digit in `1…9`, i.e. a valid placeholder for a
/// numbered-digit binding (see ``ShortcutAction/usesNumberedDigitMatching``).
/// Anything else (a letter, `0`, a named key) is not an active numbered
/// shortcut and must not be rendered as the `1…9` range.
func isNumberedDigitKey(_ key: String) -> Bool {
    shortcutFormatter.isNumberedDigitKey(key)
}

/// Formats a single ``ShortcutStroke`` with the legacy symbol order
/// (modifier symbols `⌃⌥⇧⌘` followed by ``shortcutKeyDisplayString(_:)``).
func shortcutStrokeDisplayString(_ stroke: ShortcutStroke) -> String {
    shortcutFormatter.displayString(stroke)
}

/// Formats just the modifier symbols of a ``ShortcutStroke`` (`⌃⌥⇧⌘`),
/// omitting the key glyph. Used for numbered-digit bindings where the key
/// is replaced by the ``numberedDigitRangeHint``.
func shortcutModifierDisplayString(_ stroke: ShortcutStroke) -> String {
    shortcutFormatter.modifierDisplayString(stroke)
}

/// Formats the shared named-key tokens that can appear in stored shortcuts.
func shortcutKeyDisplayString(_ key: String) -> String {
    shortcutFormatter.keyDisplayString(key)
}
