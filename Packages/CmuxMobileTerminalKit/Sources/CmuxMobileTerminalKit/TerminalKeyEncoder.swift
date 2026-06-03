public import Foundation

/// Byte-exact VT encoder for terminal key input.
///
/// Absorbs the static byte tables that previously lived in the iOS
/// `TerminalHardwareKeyResolver` (special keys + control/alt sequences) plus
/// the Command/Alt readline mappings inlined in the input view, so every
/// keystroke-to-bytes translation has a single, platform-neutral, testable
/// home. The produced bytes are identical to the legacy UIKit path.
///
/// All methods are pure and `static`; the encoder holds no state.
public struct TerminalKeyEncoder {
    private init() {}

    private static let supportedModifierFlags: TerminalKeyModifier = [.shift, .control, .alternate]

    /// Encodes a special (non-character) key with the given modifiers.
    ///
    /// - Parameters:
    ///   - key: The special key pressed.
    ///   - modifiers: The active modifier flags. Only `shift`, `control`, and
    ///     `alternate` are considered; other bits are ignored.
    /// - Returns: The VT byte sequence, or `nil` when the combination has no
    ///   defined encoding.
    public static func encode(specialKey key: TerminalSpecialKey, modifiers: TerminalKeyModifier) -> Data? {
        let flags = modifiers.intersection(supportedModifierFlags)
        switch (key, flags) {
        case (.leftArrow, [.alternate]):
            return Data([0x1B, 0x62])
        case (.rightArrow, [.alternate]):
            return Data([0x1B, 0x66])
        case (.upArrow, []):
            return Data([0x1B, 0x5B, 0x41])
        case (.downArrow, []):
            return Data([0x1B, 0x5B, 0x42])
        case (.rightArrow, []):
            return Data([0x1B, 0x5B, 0x43])
        case (.leftArrow, []):
            return Data([0x1B, 0x5B, 0x44])
        case (.home, []):
            return Data([0x1B, 0x5B, 0x48])
        case (.end, []):
            return Data([0x1B, 0x5B, 0x46])
        case (.pageUp, []):
            return Data([0x1B, 0x5B, 0x35, 0x7E])
        case (.pageDown, []):
            return Data([0x1B, 0x5B, 0x36, 0x7E])
        case (.delete, []):
            return Data([0x1B, 0x5B, 0x33, 0x7E])
        case (.delete, [.alternate]):
            return Data([0x1B, 0x7F])
        case (.escape, []):
            return Data([0x1B])
        case (.tab, []):
            return Data([0x09])
        case (.tab, [.shift]):
            return Data([0x1B, 0x5B, 0x5A])
        default:
            return nil
        }
    }

    /// Encodes a character key with the given modifiers.
    ///
    /// Only Control (and Control+Shift) combinations produce a sequence; an
    /// unmodified character returns `nil` because the soft keyboard inserts it
    /// directly.
    ///
    /// - Parameters:
    ///   - input: The single-character input string.
    ///   - modifiers: The active modifier flags.
    /// - Returns: The control byte for `Control`-modified input, otherwise `nil`.
    public static func encode(character input: String, modifiers: TerminalKeyModifier) -> Data? {
        let flags = modifiers.intersection(supportedModifierFlags)
        if flags == [.control] || flags == [.control, .shift] {
            return controlCharacter(for: input)
        }
        return nil
    }

    /// Maps a single character to its control byte (`Ctrl+<char>`).
    ///
    /// Implements the exact mapping the legacy resolver used, including the
    /// numeric/symbolic aliases (`Ctrl+Space`/`Ctrl+2` → NUL, `Ctrl+3` → ESC,
    /// `Ctrl+/` → 0x1F, `Ctrl+?` → DEL).
    ///
    /// - Parameter input: The single character to control-encode.
    /// - Returns: The control byte, or `nil` when the character has no mapping.
    public static func controlCharacter(for input: String) -> Data? {
        switch input {
        case " ":
            return Data([0x00])
        case "2":
            return Data([0x00])
        case "3":
            return Data([0x1B])
        case "4":
            return Data([0x1C])
        case "5":
            return Data([0x1D])
        case "6":
            return Data([0x1E])
        case "7":
            return Data([0x1F])
        case "/":
            return Data([0x1F])
        case "?":
            return Data([0x7F])
        default:
            break
        }

        guard let scalar = input.uppercased().unicodeScalars.first,
              input.unicodeScalars.count == 1 else { return nil }
        guard (0x40...0x5F).contains(scalar.value) else { return nil }
        return Data([UInt8(scalar.value & 0x1F)])
    }

    /// The Alt-prefixed sequence for committed text typed with Alt armed.
    ///
    /// Prepends ESC (`0x1B`) to the UTF-8 bytes of `text`, matching the legacy
    /// `alternateSequence(for:)` behavior.
    ///
    /// - Parameter text: The committed text.
    /// - Returns: `ESC` + UTF-8 bytes, or `nil` when `text` encodes to nothing.
    public static func altPrefixed(_ text: String) -> Data? {
        guard let encoded = text.data(using: .utf8), !encoded.isEmpty else { return nil }
        var sequence = Data([0x1B])
        sequence.append(encoded)
        return sequence
    }

    /// Maps Cmd+<letter> typed through the soft keyboard to Mac-terminal
    /// readline shortcuts (e.g. Cmd+A → start of line).
    ///
    /// - Parameter text: The committed single-character text.
    /// - Returns: The readline control byte, or `nil` when unmapped.
    public static func commandReadline(for text: String) -> Data? {
        guard text.count == 1, let char = text.lowercased().first else { return nil }
        switch char {
        case "a": return Data([0x01]) // Ctrl+A - beginning of line
        case "e": return Data([0x05]) // Ctrl+E - end of line
        case "k": return Data([0x0B]) // Ctrl+K - kill to end of line
        case "u": return Data([0x15]) // Ctrl+U - kill to start of line
        case "w": return Data([0x17]) // Ctrl+W - delete previous word
        case "l": return Data([0x0C]) // Ctrl+L - clear screen
        case "c": return Data([0x03]) // Ctrl+C - SIGINT
        case "d": return Data([0x04]) // Ctrl+D - EOF
        default: return nil
        }
    }
}
