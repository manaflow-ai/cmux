import CmuxSettings
import SwiftUI

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
    if shortcut.isUnbound {
        return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
    }
    if numbered {
        // The digit is a placeholder for the whole 1…9 range, so show the
        // range hint after the modifiers instead of the literal key. A
        // chorded numbered binding keeps its first stroke verbatim and
        // applies the range to the (modifiers-only) second stroke.
        if let chord = shortcut.second {
            return shortcutStrokeDisplayString(shortcut.first)
                + " "
                + shortcutModifierDisplayString(chord)
                + numberedDigitRangeHint
        }
        return shortcutModifierDisplayString(shortcut.first) + numberedDigitRangeHint
    }
    if let chord = shortcut.second {
        return shortcutStrokeDisplayString(shortcut.first)
            + " "
            + shortcutStrokeDisplayString(chord)
    }
    return shortcutStrokeDisplayString(shortcut.first)
}

/// The `1…9` range glyph shown for numbered-digit bindings. A
/// language-neutral numeric range, so it is not localized — matching the
/// `"1…9"` literal baked into the numbered actions' display names.
let numberedDigitRangeHint = "1…9"

/// Formats a single ``ShortcutStroke`` with the legacy symbol order
/// (modifier symbols `⌃⌥⇧⌘` followed by ``shortcutKeyDisplayString(_:)``).
func shortcutStrokeDisplayString(_ stroke: ShortcutStroke) -> String {
    shortcutModifierDisplayString(stroke) + shortcutKeyDisplayString(stroke.key)
}

/// Formats just the modifier symbols of a ``ShortcutStroke`` (`⌃⌥⇧⌘`),
/// omitting the key glyph. Used for numbered-digit bindings where the key
/// is replaced by the ``numberedDigitRangeHint``.
func shortcutModifierDisplayString(_ stroke: ShortcutStroke) -> String {
    var result = ""
    if stroke.control { result.append("⌃") }
    if stroke.option { result.append("⌥") }
    if stroke.shift { result.append("⇧") }
    if stroke.command { result.append("⌘") }
    return result
}

/// Mirrors the legacy `ShortcutStroke.keyDisplayString` for the common
/// named-key tokens that can appear in stored shortcuts, falling back to
/// the uppercased raw key for plain letters and digits.
func shortcutKeyDisplayString(_ key: String) -> String {
    switch key {
    case "\t":
        return String(localized: "shortcut.key.tab", defaultValue: "Tab")
    case "space":
        return String(localized: "shortcut.key.space", defaultValue: "Space")
    case "\r":
        return "↩"
    case "media.brightnessDown":
        return String(localized: "shortcut.key.mediaBrightnessDown", defaultValue: "Brightness Down")
    case "media.brightnessUp":
        return String(localized: "shortcut.key.mediaBrightnessUp", defaultValue: "Brightness Up")
    case "media.mute":
        return String(localized: "shortcut.key.mediaMute", defaultValue: "Mute")
    case "media.next":
        return String(localized: "shortcut.key.mediaNext", defaultValue: "Next Track")
    case "media.playPause":
        return String(localized: "shortcut.key.mediaPlayPause", defaultValue: "Play/Pause")
    case "media.previous":
        return String(localized: "shortcut.key.mediaPrevious", defaultValue: "Previous Track")
    case "media.volumeDown":
        return String(localized: "shortcut.key.mediaVolumeDown", defaultValue: "Volume Down")
    case "media.volumeUp":
        return String(localized: "shortcut.key.mediaVolumeUp", defaultValue: "Volume Up")
    default:
        return key.uppercased()
    }
}
