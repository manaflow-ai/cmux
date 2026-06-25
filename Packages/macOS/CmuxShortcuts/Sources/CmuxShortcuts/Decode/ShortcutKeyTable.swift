public import AppKit

/// The pure key-code/character mapping tables a recorded or configured keyboard
/// shortcut is matched and recorded against.
///
/// ## Why this type exists
///
/// Turning a physical key into the cmux stored-shortcut vocabulary ("←", "f3",
/// "media.playPause", "]", "1", …) is a set of fixed lookups: which glyph a key
/// code records as, which `F`-key a special key is, which HID usage a media key
/// is, which physical key code a stored shortcut key maps back to, and which
/// shortcut keys are matched by key code rather than by character. None of this
/// depends on the app's window, tab, focus, or any AppKit instance state, so it
/// is a value type in the shortcut package rather than a pile of `private static`
/// members on the app-target `ShortcutStroke`.
///
/// The only AppKit dependency is `NSEvent.ModifierFlags`, which appears purely as
/// a value-typed parameter for modifier normalization; the type holds no AppKit
/// reference state and is `Sendable`.
///
/// ## Faithful relocation
///
/// Every table here is a byte-faithful lift of the corresponding `private static`
/// member that lived on the app-target `ShortcutStroke` (in
/// `KeyboardShortcutSettings.swift`). `ShortcutStroke` keeps its `NSEvent`-driven
/// `matches(...)`/`recordingResult(...)` entry points and forwards each table
/// lookup here. The lookups are exhaustive switches with no fallthrough side
/// effects, so the relocation changes no behavior.
///
/// - Note: ``ShortcutCoordinator`` carries its own decode-path copies of the
///   `normalizedShortcutEventCharacter`/`digitForNumberKeyCode` transforms for
///   the configured-shortcut *dispatch* seam (`ShortcutEventDecoding`). Those and
///   the copies here are the same concept reached through two different caller
///   paths; deduplicating them onto this single source of truth is a follow-up
///   once both caller paths are package-side. TODO(refactor): collapse
///   `ShortcutCoordinator.normalizedShortcutEventCharacter` /
///   `digitForNumberKeyCode` to forward to `ShortcutKeyTable`.
public struct ShortcutKeyTable: Sendable {
    /// A key the recorder accepts, paired with the physical key code the event
    /// reported for it.
    ///
    /// Faithful relocation of the former `ShortcutStroke.RecordableKey` nested
    /// type; the recorder stores `keyCode` so direct-key-code matching (function
    /// keys, media keys, space, arrows) can use the exact physical code.
    public struct RecordableKey: Sendable, Equatable {
        /// The cmux stored-shortcut key string (e.g. `"f3"`, `"]"`, `"media.mute"`).
        public let key: String
        /// The physical key code the event reported, or `nil` when none applies.
        public let keyCode: UInt16?

        /// Creates a recordable key.
        public init(key: String, keyCode: UInt16?) {
            self.key = key
            self.keyCode = keyCode
        }
    }

    /// Creates a key table. The type is stateless; the initializer exists so the
    /// owning `ShortcutStroke` constructs a value rather than calling members on a
    /// caseless namespace type.
    public init() {}

    /// The cmux stored-shortcut key string a recorded `keyCode`/character pair
    /// maps to, or `nil` when the key is not recordable.
    ///
    /// Prefers the key-code mapping so shifted symbol keys (e.g. "}") record as
    /// their base ("]"); falls back to the lowercased first character when it is a
    /// letter or number. Faithful relocation of `ShortcutStroke.storedKey(keyCode:charactersIgnoringModifiers:)`.
    public func storedKey(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?
    ) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
        case 49: return "space" // kVK_Space
        case 36, 76: return "\r" // return, keypad enter
        case 33: return "["  // kVK_ANSI_LeftBracket
        case 30: return "]"  // kVK_ANSI_RightBracket
        case 27: return "-"  // kVK_ANSI_Minus
        case 24: return "="  // kVK_ANSI_Equal
        case 43: return ","  // kVK_ANSI_Comma
        case 47: return "."  // kVK_ANSI_Period
        case 44: return "/"  // kVK_ANSI_Slash
        case 41: return ";"  // kVK_ANSI_Semicolon
        case 39: return "'"  // kVK_ANSI_Quote
        case 50: return "`"  // kVK_ANSI_Grave
        case 42: return "\\" // kVK_ANSI_Backslash
        default:
            break
        }

        guard let chars = charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }

    /// The recordable key an `NSEvent.SpecialKey` in the F1–F20 range maps to,
    /// preserving the event's physical key code, or `nil` for any other special
    /// key. Faithful relocation of `ShortcutStroke.recordableKey(from:eventKeyCode:)`.
    public func recordableKey(
        from specialKey: NSEvent.SpecialKey,
        eventKeyCode: UInt16
    ) -> RecordableKey? {
        switch specialKey {
        case .f1: return RecordableKey(key: "f1", keyCode: eventKeyCode)
        case .f2: return RecordableKey(key: "f2", keyCode: eventKeyCode)
        case .f3: return RecordableKey(key: "f3", keyCode: eventKeyCode)
        case .f4: return RecordableKey(key: "f4", keyCode: eventKeyCode)
        case .f5: return RecordableKey(key: "f5", keyCode: eventKeyCode)
        case .f6: return RecordableKey(key: "f6", keyCode: eventKeyCode)
        case .f7: return RecordableKey(key: "f7", keyCode: eventKeyCode)
        case .f8: return RecordableKey(key: "f8", keyCode: eventKeyCode)
        case .f9: return RecordableKey(key: "f9", keyCode: eventKeyCode)
        case .f10: return RecordableKey(key: "f10", keyCode: eventKeyCode)
        case .f11: return RecordableKey(key: "f11", keyCode: eventKeyCode)
        case .f12: return RecordableKey(key: "f12", keyCode: eventKeyCode)
        case .f13: return RecordableKey(key: "f13", keyCode: eventKeyCode)
        case .f14: return RecordableKey(key: "f14", keyCode: eventKeyCode)
        case .f15: return RecordableKey(key: "f15", keyCode: eventKeyCode)
        case .f16: return RecordableKey(key: "f16", keyCode: eventKeyCode)
        case .f17: return RecordableKey(key: "f17", keyCode: eventKeyCode)
        case .f18: return RecordableKey(key: "f18", keyCode: eventKeyCode)
        case .f19: return RecordableKey(key: "f19", keyCode: eventKeyCode)
        case .f20: return RecordableKey(key: "f20", keyCode: eventKeyCode)
        default:
            return nil
        }
    }

    /// The media-key recordable key a system-defined event's HID payload maps to,
    /// or `nil` when the payload is not a recognized media key-down.
    ///
    /// `data1` is the raw `NSEvent.data1`; the high 16 bits are the HID usage and
    /// bits 8–15 are the key state (only `0x0A`, key down, is accepted). Faithful
    /// relocation of `ShortcutStroke.mediaKey(from:)`, with the `NSEvent`
    /// extraction (subtype/data1) left to the app-target forwarder.
    public func mediaKey(
        systemDefinedSubtype: Int16,
        data1: Int
    ) -> RecordableKey? {
        guard systemDefinedSubtype == Int16(8) else {
            return nil
        }

        let raw = UInt32(truncatingIfNeeded: data1)
        let keyCode = UInt16((raw & 0xFFFF0000) >> 16)
        let keyState = UInt8((raw & 0x0000FF00) >> 8)
        guard keyState == 0x0A else { return nil }

        switch keyCode {
        case 0: return RecordableKey(key: "media.volumeUp", keyCode: keyCode)
        case 1: return RecordableKey(key: "media.volumeDown", keyCode: keyCode)
        case 2: return RecordableKey(key: "media.brightnessUp", keyCode: keyCode)
        case 3: return RecordableKey(key: "media.brightnessDown", keyCode: keyCode)
        case 7: return RecordableKey(key: "media.mute", keyCode: keyCode)
        case 16: return RecordableKey(key: "media.playPause", keyCode: keyCode)
        case 17: return RecordableKey(key: "media.next", keyCode: keyCode)
        case 18: return RecordableKey(key: "media.previous", keyCode: keyCode)
        default:
            return nil
        }
    }

    /// Maps a printed shortcut character to the base key it should match against,
    /// undoing Shift-symbol production so `!`→`1`, `{`→`[`, `?`→`/`, and the
    /// always-on European-layout cases `+`→`=` / `_`→`-`.
    ///
    /// Faithful relocation of `ShortcutStroke.normalizedShortcutEventCharacter(_:applyShiftSymbolNormalization:eventKeyCode:)`.
    public func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()

        // "+" -> "=" and "_" -> "-" are normalized regardless of Shift. On US
        // layouts these symbols only exist as Shift variants, so the Shift gate
        // below historically sufficed. On European layouts (German QWERTZ, French
        // AZERTY, Nordic) "+" and "-" are dedicated keys typed WITHOUT Shift, so a
        // bare "+"/"_" can only originate from such a key. Mapping them to their
        // base zoom key ("=", "-") unconditionally is therefore safe (no shortcut
        // key is ever stored as "+"/"_") and is what makes Cmd zoom work there.
        switch lowered {
        case "+": return "="
        case "_": return "-"
        default: break
        }

        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    /// Whether a single-letter Command shortcut requires a character match (as
    /// opposed to allowing the ANSI key-code fallback). Faithful relocation of
    /// `ShortcutStroke.shouldRequireCharacterMatchForCommandShortcut(shortcutKey:)`.
    public func shouldRequireCharacterMatchForCommandShortcut(shortcutKey: String) -> Bool {
        guard shortcutKey.count == 1, let scalar = shortcutKey.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    /// Whether the printed `eventCharacter`, after normalization, equals the
    /// stored `shortcutKey`. Faithful relocation of
    /// `ShortcutStroke.shortcutCharacterMatches(eventCharacter:shortcutKey:applyShiftSymbolNormalization:eventKeyCode:)`.
    public func shortcutCharacterMatches(
        eventCharacter: String?,
        shortcutKey: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Bool {
        guard let eventCharacter, !eventCharacter.isEmpty else { return false }
        return normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        ) == shortcutKey
    }

    /// The physical key code a stored shortcut key maps back to, or `nil` when the
    /// key has no fixed code. Faithful relocation of
    /// `ShortcutStroke.keyCodeForShortcutKey(_:)`.
    public func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        switch key {
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        case "f13": return 105
        case "f14": return 107
        case "f15": return 113
        case "f16": return 106
        case "f17": return 64
        case "f18": return 79
        case "f19": return 80
        case "f20": return 90
        case "media.volumeUp": return 0
        case "media.volumeDown": return 1
        case "media.brightnessUp": return 2
        case "media.brightnessDown": return 3
        case "media.mute": return 7
        case "media.playPause": return 16
        case "media.next": return 17
        case "media.previous": return 18
        case "space": return 49
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "\t": return 48
        case "`": return 50
        case "\r": return 36
        case "←": return 123
        case "→": return 124
        case "↓": return 125
        case "↑": return 126
        default:
            return nil
        }
    }

    /// Whether a stored shortcut key is matched by physical key code rather than
    /// by produced character (space, function keys, and media keys). Faithful
    /// relocation of `ShortcutStroke.usesDirectKeyCodeMatching(_:)`.
    public func usesDirectKeyCodeMatching(_ key: String) -> Bool {
        key == "space" || functionKeyDisplayString(for: key) != nil || key.hasPrefix("media.")
    }

    /// The `F`-key display string (e.g. `"F3"`) for a stored function-key key, or
    /// `nil` when the key is not `f1`–`f20`. Faithful relocation of
    /// `ShortcutStroke.functionKeyDisplayString(for:)`.
    public func functionKeyDisplayString(for key: String) -> String? {
        guard key.hasPrefix("f"),
              let number = Int(key.dropFirst()),
              (1...20).contains(number) else {
            return nil
        }
        return "F\(number)"
    }

    /// The digit 1–9 a physical number-row key code maps to, or `nil`. The 0 key
    /// (kVK_ANSI_0, keyCode 29) is intentionally excluded: numbered shortcuts run
    /// 1–9 only. Faithful relocation of `ShortcutStroke.digitForNumberKeyCode(_:)`.
    public func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default:
            return nil
        }
    }

    /// The full set of physical key codes a layout-character resolution iterates
    /// when matching a stored shortcut key with no fixed code. Faithful relocation
    /// of `ShortcutStroke.supportedShortcutKeyCodes`.
    public var supportedShortcutKeyCodes: [UInt16] {
        [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
            33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
            50, 123, 124, 125, 126,
        ]
    }
}
