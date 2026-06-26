/// A physical keyboard key identified by its Carbon/ANSI virtual key code,
/// mediating the pure bidirectional mapping between a key code, the printed
/// character an event produced, and the normalized glyph a `StoredShortcut`
/// records.
///
/// ## Why this value exists
///
/// Configured-shortcut matching in the app target needs three pure lookups that
/// reach no window, tab, or focus state: turn a stored key glyph into the
/// physical key code it should match (``init(storedKey:)``), turn a physical key
/// code plus the event's `charactersIgnoringModifiers` into the stored glyph it
/// records as (``storedKey(charactersIgnoringModifiers:)``), and normalize a
/// printed Shift-symbol back to its base glyph
/// (``normalizedEventCharacter(_:applyShiftSymbolNormalization:normalizePlusMinusRegardlessOfShift:)``).
/// Because all three key off, or produce, a physical key code, they cohere on
/// this value.
///
/// ## Faithful relocation
///
/// Byte-faithful move of the former private `static` helpers
/// `keyCodeForShortcutKey`, `storedKey`, and `normalizedShortcutEventCharacter`
/// on the app target's `ShortcutStroke`. The glyph→key-code helper is now the
/// failable ``init(storedKey:)``; its printable-ANSI rows delegate to
/// ``ParsedShortcutCombo/keyCodeForShortcutKey(_:)`` (the package's single
/// printable table) so that table is not duplicated, and `nil` still means the
/// glyph names no known key. The normalize switch body is unchanged apart from
/// reading `self.keyCode`; its `normalizePlusMinusRegardlessOfShift` flag lets
/// ``ShortcutCoordinator`` share this one implementation while keeping its own
/// Shift-gated `+`/`_` behavior.
public struct PhysicalShortcutKey: Equatable, Hashable, Sendable {
    /// The Carbon/ANSI virtual key code of the physical key.
    public let keyCode: UInt16

    /// Wraps a known physical key code.
    public init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    /// The physical key a stored shortcut glyph (`"h"`, `"f5"`, `"media.mute"`,
    /// `"←"`, `"\r"`) is bound to, or `nil` when the glyph names no known key.
    ///
    /// The binding-only keys a stored shortcut can name (function keys, media
    /// keys, `space`, tab, return, arrows) are mapped here; every printable-ANSI
    /// glyph falls through to ``ParsedShortcutCombo/keyCodeForShortcutKey(_:)``,
    /// the package's single printable-table source of truth, so the printable
    /// rows are not duplicated. None of the binding-only glyphs appears in that
    /// table, so the explicit cases and the fallback never overlap.
    public init?(storedKey key: String) {
        switch key {
        case "f1": self.keyCode = 122
        case "f2": self.keyCode = 120
        case "f3": self.keyCode = 99
        case "f4": self.keyCode = 118
        case "f5": self.keyCode = 96
        case "f6": self.keyCode = 97
        case "f7": self.keyCode = 98
        case "f8": self.keyCode = 100
        case "f9": self.keyCode = 101
        case "f10": self.keyCode = 109
        case "f11": self.keyCode = 103
        case "f12": self.keyCode = 111
        case "f13": self.keyCode = 105
        case "f14": self.keyCode = 107
        case "f15": self.keyCode = 113
        case "f16": self.keyCode = 106
        case "f17": self.keyCode = 64
        case "f18": self.keyCode = 79
        case "f19": self.keyCode = 80
        case "f20": self.keyCode = 90
        case "media.volumeUp": self.keyCode = 0
        case "media.volumeDown": self.keyCode = 1
        case "media.brightnessUp": self.keyCode = 2
        case "media.brightnessDown": self.keyCode = 3
        case "media.mute": self.keyCode = 7
        case "media.playPause": self.keyCode = 16
        case "media.next": self.keyCode = 17
        case "media.previous": self.keyCode = 18
        case "space": self.keyCode = 49
        case "\t": self.keyCode = 48
        case "\r": self.keyCode = 36
        case "←": self.keyCode = 123
        case "→": self.keyCode = 124
        case "↓": self.keyCode = 125
        case "↑": self.keyCode = 126
        default:
            guard let code = ParsedShortcutCombo.keyCodeForShortcutKey(key) else {
                return nil
            }
            self.keyCode = code
        }
    }

    /// The stored shortcut glyph this physical key records as, given the event's
    /// `charactersIgnoringModifiers`, or `nil` when the key produces no
    /// recordable glyph.
    ///
    /// Prefers the key-code mapping so shifted symbol keys (e.g. `}`) record as
    /// their base glyph (`]`); falls back to the first letter/number of the
    /// lowercased characters otherwise.
    public func storedKey(charactersIgnoringModifiers: String?) -> String? {
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

    /// Maps a printed shortcut character to the base key it should match against,
    /// undoing Shift-symbol production so `!`→`1`, `{`→`[`, `?`→`/`, `+`→`=`, and
    /// `_`→`-`.
    ///
    /// `applyShiftSymbolNormalization` gates the Shift-only symbol table. The
    /// ambiguous symbols (`<`, `>`, `!`…`)`) only normalize when this physical key
    /// code is the matching base key.
    ///
    /// `normalizePlusMinusRegardlessOfShift` controls the one place the two
    /// historical callers diverged. When `true` (the configured-shortcut matcher
    /// lifted from `ShortcutStroke`), `+`→`=` and `_`→`-` apply even without
    /// Shift: on European layouts (German QWERTZ, French AZERTY, Nordic) `+`/`-`
    /// are dedicated keys typed WITHOUT Shift, so a bare `+`/`_` can only
    /// originate from such a key; mapping them to their base zoom key is safe (no
    /// shortcut is ever stored as `+`/`_`) and is what makes Cmd zoom work there.
    /// When `false` (the numbered-digit decoder lifted from `AppDelegate`), `+`/`_`
    /// normalize only under Shift, exactly as that path always did. Either way the
    /// Shift table maps `+`/`_`, so the only behavioral difference is whether they
    /// also normalize with Shift up.
    public func normalizedEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        normalizePlusMinusRegardlessOfShift: Bool
    ) -> String {
        let lowered = eventCharacter.lowercased()

        if normalizePlusMinusRegardlessOfShift {
            switch lowered {
            case "+": return "="
            case "_": return "-"
            default: break
            }
        }

        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return keyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return keyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return keyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return keyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return keyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return keyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return keyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return keyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return keyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return keyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return keyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return keyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }
}
