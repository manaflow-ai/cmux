public import AppKit
import Foundation

/// Right-sidebar keyboard-navigation parsing.
///
/// These computed properties decode a raw `NSEvent` keyDown into the sidebar's
/// vi-style navigation intents (move, disclosure, focus-filter slash, plain
/// typing). They replace the former `RightSidebarKeyboardNavigation` caseless
/// namespace-enum of static parsers: the operation belongs on the type it
/// inspects. Pure, side-effect-free, and behavior byte-faithful to the legacy
/// parsers, including the exact keyCode and modifier-mask checks.
extension NSEvent {
    /// Vertical move delta for a list selection: `+1` (down/next), `-1`
    /// (up/previous), or `nil` when the event is not a plain move key.
    ///
    /// Accepts Ctrl+N / Ctrl+P (with no Command or Option), and the unmodified
    /// J/Down (next) and K/Up (previous) keys.
    public var rightSidebarMoveDelta: Int? {
        guard type == .keyDown else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    /// Tree-disclosure intent for the focused row, or `nil` when the event is
    /// not an unmodified H/L or Left/Right key.
    public var rightSidebarDisclosureAction: RightSidebarDisclosureAction? {
        guard type == .keyDown else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    /// Whether the event is an unmodified `/` keypress (opens the focus
    /// filter).
    public var isPlainRightSidebarSlash: Bool {
        guard type == .keyDown else { return false }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return keyCode == 44
    }

    /// Whether the event is unmodified printable text (a character that should
    /// start typing into the focus filter rather than trigger a shortcut).
    public var isPlainRightSidebarPrintableText: Bool {
        guard type == .keyDown else { return false }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}
