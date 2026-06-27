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

        // Option+Backspace word-delete reuses the forward-delete special key with
        // Alt to emit ESC DEL (meta-backspace). The iOS input view's
        // `deleteBackward()` path depends on this exact mapping, so keep it as an
        // explicit precedence case ahead of the generic CSI `~` delete form below.
        if key == .delete, flags == [.alternate] {
            return Data([0x1B, 0x7F])
        }

        switch key {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            return cursorSequence(key, flags)
        case .home, .end, .delete, .pageUp, .pageDown:
            return editKeySequence(key, flags)
        case .escape:
            // Modified Escape has no distinct terminal encoding; only the bare key.
            return flags.isEmpty ? Data([0x1B]) : nil
        case .tab:
            if flags.isEmpty { return Data([0x09]) }
            // Shift+Tab is back-tab (CSI Z); other Tab modifiers are undefined.
            if flags == [.shift] { return Data([0x1B, 0x5B, 0x5A]) }
            return nil
        }
    }

    // MARK: xterm modifier matrix

    /// The xterm modifier parameter `m = 1 + shift + alt*2 + ctrl*4`, so an
    /// unmodified key yields `1` (the bare sequence) and every combination above
    /// it selects the `CSI 1 ; m <final>` (arrows) / `CSI n ; m ~` (nav) modified
    /// form. `m` stays a single decimal digit across the supported set (1...8).
    private static func xtermModifierParameter(_ flags: TerminalKeyModifier) -> Int {
        var value = 1
        if flags.contains(.shift) { value += 1 }
        if flags.contains(.alternate) { value += 2 }
        if flags.contains(.control) { value += 4 }
        return value
    }

    /// Cursor (arrow) keys.
    ///
    /// - **Ctrl OR Option + Left/Right** emit the readline META word-movement
    ///   bytes `ESC b` / `ESC f` — the ONLY word-move binding zsh/bash ship by
    ///   default. Both xterm cursor forms — `ESC [ 1 ; 5 D` (Ctrl) and
    ///   `ESC [ 1 ; 3 D` (Alt), `…C` for right — are UNBOUND in default
    ///   zsh/bash, so the shell swallows the ESC and self-inserts the rest as
    ///   literal `"[1;5D"` / `"[1;3D"` text — the real-device regression this
    ///   avoids. Ctrl+Shift / Option+Shift + Left/Right collapse to the same
    ///   word-move bytes. Option-only Up/Down have no META word-move and would
    ///   echo `"[1;3A"` the same way, so they are suppressed (`nil`, a no-op);
    ///   Ctrl(+anything) Up/Down keep the xterm matrix form below.
    /// - **Everything else** uses the xterm matrix: bare `ESC [ <final>` when
    ///   unmodified, otherwise `ESC [ 1 ; <m> <final>` — e.g. Shift+Left →
    ///   `ESC [ 1 ; 2 D`, Ctrl+Up → `ESC [ 1 ; 5 A`, Shift+Up →
    ///   `ESC [ 1 ; 2 A`. Every modified form carries the leading ESC (`0x1B`).
    private static func cursorSequence(_ key: TerminalSpecialKey, _ flags: TerminalKeyModifier) -> Data? {
        // Ctrl or Option on the horizontal arrows = readline META word-move.
        if flags.contains(.control) || flags.contains(.alternate) {
            switch key {
            case .leftArrow: return Data([0x1B, 0x62])   // ESC b — backward-word
            case .rightArrow: return Data([0x1B, 0x66])  // ESC f — forward-word
            case .upArrow, .downArrow:
                // No META vertical word-move. Option-only Up/Down echo the
                // shell-unbound xterm "[1;3A"/"[1;3B" literally, so suppress;
                // Ctrl/Ctrl+Alt verticals fall through to the xterm matrix.
                if flags == [.alternate] { return nil }
            default: break
            }
        }
        guard let finalByte = cursorFinalByte(key) else { return nil }
        let m = xtermModifierParameter(flags)
        if m == 1 { return Data([0x1B, 0x5B, finalByte]) }  // bare ESC [ <final>
        var bytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x3B]   // ESC [ 1 ;
        bytes.append(contentsOf: Array("\(m)".utf8))    // m (single digit 2…8)
        bytes.append(finalByte)                         // A | B | C | D
        return Data(bytes)
    }

    private static func cursorFinalByte(_ key: TerminalSpecialKey) -> UInt8? {
        switch key {
        case .upArrow: return 0x41    // A
        case .downArrow: return 0x42  // B
        case .rightArrow: return 0x43 // C
        case .leftArrow: return 0x44  // D
        default: return nil
        }
    }

    /// Navigation/editing keys (Home/End/Delete/PageUp/PageDown): the bare VT form
    /// when unmodified, otherwise the xterm `ESC [ <n> ; <m> ~` form — e.g.
    /// Shift+End → `ESC [ 4 ; 2 ~`, Ctrl+Delete → `ESC [ 3 ; 5 ~`. Home/End keep
    /// their short `ESC [ H` / `ESC [ F` form only while unmodified.
    private static func editKeySequence(_ key: TerminalSpecialKey, _ flags: TerminalKeyModifier) -> Data? {
        guard let n = editKeyNumber(key) else { return nil }
        let m = xtermModifierParameter(flags)
        if m == 1 {
            switch key {
            case .home: return Data([0x1B, 0x5B, 0x48]) // ESC [ H
            case .end: return Data([0x1B, 0x5B, 0x46])  // ESC [ F
            default:
                var bytes: [UInt8] = [0x1B, 0x5B]
                bytes.append(contentsOf: Array("\(n)".utf8))
                bytes.append(0x7E) // ~
                return Data(bytes)
            }
        }
        var bytes: [UInt8] = [0x1B, 0x5B]
        bytes.append(contentsOf: Array("\(n)".utf8))    // n
        bytes.append(0x3B)                              // ;
        bytes.append(contentsOf: Array("\(m)".utf8))    // m
        bytes.append(0x7E)                              // ~
        return Data(bytes)
    }

    /// The CSI `~` parameter `n` for each navigation key (Home 1, Insert 2,
    /// Delete 3, End 4, PageUp 5, PageDown 6). Insert is omitted because no iOS
    /// hardware key reports it; add a `.insert` special key + case here to wire it.
    private static func editKeyNumber(_ key: TerminalSpecialKey) -> Int? {
        switch key {
        case .home: return 1
        case .delete: return 3
        case .end: return 4
        case .pageUp: return 5
        case .pageDown: return 6
        default: return nil
        }
    }

    /// Encodes a character key with the given modifiers.
    ///
    /// Control combinations produce the C0 control byte; Option/Alt combinations
    /// produce the meta form (`ESC` then the character, e.g. Alt+b → `ESC b` for
    /// back-word); Ctrl+Alt combines both (`ESC` then the C0 byte). An unmodified
    /// (or Shift-only) character returns `nil` because the soft keyboard inserts
    /// it directly.
    ///
    /// - Parameters:
    ///   - input: The single-character input string.
    ///   - modifiers: The active modifier flags.
    /// - Returns: The encoded bytes, or `nil` when the combination has no
    ///   terminal sequence (plain/Shift-only character).
    public static func encode(character input: String, modifiers: TerminalKeyModifier) -> Data? {
        let flags = modifiers.intersection(supportedModifierFlags)
        if flags.contains(.control) {
            guard let control = controlCharacter(for: input) else { return nil }
            // Ctrl+Alt+<char> = meta + C0: ESC then the control byte.
            guard flags.contains(.alternate) else { return control }
            var sequence = Data([0x1B])
            sequence.append(control)
            return sequence
        }
        if flags.contains(.alternate) {
            // Option/Alt+<char> = meta: ESC then the character (Alt+f → ESC f).
            return altPrefixed(input)
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
