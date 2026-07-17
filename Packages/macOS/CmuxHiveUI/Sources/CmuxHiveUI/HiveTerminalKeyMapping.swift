import AppKit
internal import CmuxMobileTerminalKit

/// Pure NSEvent-to-terminal-input mapping for the remote terminal view.
///
/// Translates one AppKit key event into either a special-key press (routed
/// through the shared ``TerminalKeyEncoder`` byte tables), a Control
/// character, or plain text. Pure and value-in/value-out so the mapping is
/// unit-testable without synthesizing real `NSEvent`s.
enum HiveTerminalKeyMapping {
    /// The terminal-input action one key event maps to.
    enum Action: Equatable {
        /// A special key (arrows, escape, tab, …) with modifiers.
        case special(TerminalSpecialKey, TerminalKeyModifier)
        /// A Control-modified character (`Ctrl+C`, …).
        case control(String)
        /// Plain text to send as-is.
        case text(String)
    }

    /// AppKit virtual key codes for the special keys terminals encode.
    private static let specialKeysByCode: [UInt16: TerminalSpecialKey] = [
        123: .leftArrow,
        124: .rightArrow,
        125: .downArrow,
        126: .upArrow,
        53: .escape,
        48: .tab,
        115: .home,
        119: .end,
        116: .pageUp,
        121: .pageDown,
        117: .delete,
    ]

    /// Map one key press to a terminal action.
    ///
    /// - Parameters:
    ///   - keyCode: The event's virtual key code.
    ///   - characters: The event's `characters`.
    ///   - charactersIgnoringModifiers: The event's base characters (used for
    ///     Control combinations, where `characters` is already the control
    ///     byte).
    ///   - modifiers: The event's modifier flags.
    /// - Returns: The action, or `nil` when the event is not terminal input
    ///   (e.g. a bare modifier or a Command shortcut the app should handle).
    static func action(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Action? {
        // Command chords belong to the app (menus, shortcuts), never the
        // remote PTY.
        if modifiers.contains(.command) { return nil }
        if let special = specialKeysByCode[keyCode] {
            return .special(special, terminalModifiers(from: modifiers))
        }
        switch keyCode {
        case 36, 76:
            // Return / keypad Enter.
            return .text("\r")
        case 51:
            // Backspace sends DEL, the shared iOS behavior.
            return .text("\u{7F}")
        default:
            break
        }
        if modifiers.contains(.control),
           let base = charactersIgnoringModifiers, !base.isEmpty {
            return .control(base)
        }
        guard let characters, !characters.isEmpty else { return nil }
        return .text(characters)
    }

    private static func terminalModifiers(from modifiers: NSEvent.ModifierFlags) -> TerminalKeyModifier {
        var result: TerminalKeyModifier = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.alternate) }
        return result
    }
}
