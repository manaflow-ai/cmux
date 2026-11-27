import Foundation

/// Per-surface model for the password input indicator.
///
/// Ghostty polls the pty's termios while a surface is focused and reports a
/// password prompt when the foreground program is in canonical mode with echo
/// off (sudo, ssh, passwd, gpg, `read -s`). This model tracks that state plus
/// how many characters were typed since it began, so cmux can draw a lock and
/// optional dots in its own chrome.
///
/// It only ever holds a count. Callers classify a keystroke into a
/// ``Keystroke`` and discard the event; the typed characters are never stored,
/// logged, or exposed.
public struct TerminalPasswordInputIndicatorState: Equatable, Sendable {
    /// What a single key press does to the hidden line being typed.
    public enum Keystroke: Equatable, Sendable {
        /// Inserts this many characters (usually 1; more for an IME commit).
        case insert(count: Int)
        /// Erases one character (Backspace, Ctrl-H).
        case deleteBackward
        /// Submits the line (Return, keypad Enter).
        case submit
        /// Discards the line (Ctrl-U kill line, Ctrl-W word erase, Ctrl-C).
        case clearLine
        /// Does not change the line (arrows, function keys, Escape, other chords).
        case ignored
    }

    /// True while the foreground program has echo off in canonical mode.
    public private(set) var isActive: Bool = false

    /// Characters typed since echo went off or since the last submit/clear.
    public private(set) var typedCount: Int = 0

    public init() {}

    /// Applies an echo state change reported by the terminal.
    ///
    /// Both directions reset the count: a new prompt starts empty, and once
    /// echo is back on there is nothing hidden left to count.
    /// - Returns: `true` when the visible state changed.
    @discardableResult
    public mutating func setEchoDisabled(_ echoDisabled: Bool) -> Bool {
        let previous = self
        isActive = echoDisabled
        typedCount = 0
        return previous != self
    }

    /// Records one key press while echo is off. A no-op when inactive.
    /// - Returns: `true` when the visible state changed.
    @discardableResult
    public mutating func record(_ keystroke: Keystroke) -> Bool {
        guard isActive else { return false }
        let previous = typedCount
        switch keystroke {
        case .insert(let count):
            typedCount += max(0, count)
        case .deleteBackward:
            typedCount = max(0, typedCount - 1)
        case .submit, .clearLine:
            typedCount = 0
        case .ignored:
            break
        }
        return previous != typedCount
    }
}

extension TerminalPasswordInputIndicatorState.Keystroke {
    /// macOS virtual key codes the classifier needs.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
    }

    /// Classifies a key press without retaining any of its text.
    ///
    /// - Parameters:
    ///   - keyCode: The hardware key code (`NSEvent.keyCode`).
    ///   - characters: The characters the key produces
    ///     (`NSEvent.characters`). Only its length and control/private-use
    ///     ranges are inspected.
    ///   - charactersIgnoringModifiers: `NSEvent.charactersIgnoringModifiers`,
    ///     used to identify control chords.
    ///   - control: Control is held.
    ///   - command: Command is held; Command chords never type into the pty.
    public static func classify(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        control: Bool,
        command: Bool
    ) -> Self {
        if command { return .ignored }
        switch keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return .submit
        case KeyCode.delete:
            return .deleteBackward
        default:
            break
        }
        if control {
            switch charactersIgnoringModifiers?.lowercased() {
            case "h": return .deleteBackward
            case "u", "w", "c": return .clearLine
            case "j", "m": return .submit
            default: return .ignored
            }
        }
        guard let characters else { return .ignored }
        return insertion(of: characters)
    }

    /// Classifies committed text (an IME commit or a keystroke's text) by
    /// counting its printable characters.
    public static func insertion(of text: String) -> Self {
        var count = 0
        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            let value = scalar.value
            // C0 controls, DEL, and AppKit's private-use function-key range
            // (arrows, F-keys, Home/End) never add a character to the line.
            if value < 0x20 && value != 0x09 { continue }
            if value == 0x7F { continue }
            if (0xF700...0xF8FF).contains(value) { continue }
            count += 1
        }
        return count > 0 ? .insert(count: count) : .ignored
    }
}
