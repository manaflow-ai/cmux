public import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut combo string (`cmd+ctrl+h`, `ctrl+1`, `enter`) parsed
/// into the typed values a synthetic `NSEvent` or a `StoredShortcut` needs.
///
/// ## Why this value exists
///
/// The debug/test surfaces in the app target (`set_shortcut`,
/// `simulate_shortcut`) accept a human-typed combo over the control socket and
/// must turn it into modifier flags, a Carbon key code, and the
/// `characters`/`charactersIgnoringModifiers` pair `NSEvent.keyEvent(...)`
/// expects. That tokenize-and-build transform is pure: it reaches no window,
/// tab, focus, or app state, so it belongs in a package rather than the
/// `TerminalController` god file it was lifted from.
///
/// ## Faithful relocation
///
/// Byte-faithful move of the former private `ParsedShortcutCombo` struct plus
/// the `parseShortcutCombo(_:)` and `keyCodeForShortcutKey(_:)` helpers. The
/// parser is now the failable ``init(combo:)``; `nil` means the combo was empty,
/// had no key token, had more than one non-modifier token, or named a key with
/// no known ANSI key code, exactly as before.
public struct ParsedShortcutCombo: Sendable {
    /// The normalized key glyph stored on a `StoredShortcut` (e.g. `"h"`, `"←"`,
    /// `"\r"`).
    public let storedKey: String
    /// The Carbon/ANSI virtual key code for the parsed key.
    public let keyCode: UInt16
    /// The modifier flags accumulated from the `cmd`/`ctrl`/`opt`/`shift` tokens.
    public let modifierFlags: NSEvent.ModifierFlags
    /// The `characters` value for a synthetic `NSEvent` built from this combo.
    public let characters: String
    /// The `charactersIgnoringModifiers` value for a synthetic `NSEvent`,
    /// including the Ctrl+letter control-character behavior the matcher exercises.
    public let charactersIgnoringModifiers: String

    /// Parses a `+`-separated shortcut combo (e.g. `cmd+ctrl+h`) into its typed
    /// components, or returns `nil` when the combo is empty, has no key token,
    /// has more than one non-modifier token, or names an unknown key.
    public init?(combo: String) {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?

        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "cmd", "command", "super":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "opt", "option", "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                // Treat as the key component.
                if keyToken == nil {
                    keyToken = part
                } else {
                    // Multiple non-modifier tokens is ambiguous.
                    return nil
                }
            }
        }

        guard var keyToken else { return nil }
        keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToken.isEmpty else { return nil }

        // Normalize a few named keys.
        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String

        switch keyToken.lowercased() {
        case "left":
            storedKey = "←"
            keyCode = 123
            charactersIgnoringModifiers = storedKey
        case "right":
            storedKey = "→"
            keyCode = 124
            charactersIgnoringModifiers = storedKey
        case "down":
            storedKey = "↓"
            keyCode = 125
            charactersIgnoringModifiers = storedKey
        case "up":
            storedKey = "↑"
            keyCode = 126
            charactersIgnoringModifiers = storedKey
        case "enter", "return":
            storedKey = "\r"
            keyCode = UInt16(kVK_Return)
            charactersIgnoringModifiers = storedKey
        default:
            let key = keyToken.lowercased()
            guard let code = Self.keyCodeForShortcutKey(key) else { return nil }
            storedKey = key
            keyCode = code

            // Replicate a common system behavior: Ctrl+letter yields a control character in
            // charactersIgnoringModifiers (e.g. Ctrl+H => backspace). This is important for
            // testing keyCode fallback matching.
            if flags.contains(.control),
               key.count == 1,
               let scalar = key.unicodeScalars.first,
               scalar.isASCII,
               scalar.value >= 97, scalar.value <= 122 { // a-z
                let upper = scalar.value - 32
                let controlValue = upper - 64 // 'A' => 1
                charactersIgnoringModifiers = String(UnicodeScalar(controlValue)!)
            } else {
                charactersIgnoringModifiers = storedKey
            }
        }

        // For our shortcut matcher, characters aren't important beyond exercising edge cases.
        let chars = charactersIgnoringModifiers

        self.storedKey = storedKey
        self.keyCode = keyCode
        self.modifierFlags = flags
        self.characters = chars
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    /// The macOS ANSI key code for a printable shortcut key glyph (`"a"`, `"5"`,
    /// `"]"`, `` "`" ``), or `nil` when the glyph is not a printable ANSI key.
    ///
    /// This is the single source of truth for the printable-ANSI glyph→key-code
    /// table in this package. ``PhysicalShortcutKey/init(storedKey:)`` reuses it
    /// for its printable rows and layers the binding-only keys (function keys,
    /// media keys, space, tab, return, arrows) on top, so the printable table is
    /// not duplicated.
    static func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
    }
}
