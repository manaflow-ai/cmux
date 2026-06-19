public import AppKit

/// A keystroke being routed against an open command palette.
///
/// The app target captures the `NSEvent`'s key code, modifier flags, and
/// reported characters into this value type; the window-agnostic policy that
/// decides whether the palette should consume the shortcut or submit on Return
/// lives here so it stays pure and testable. The contextual inputs that are not
/// part of the keystroke itself (palette visibility, the active palette `mode`)
/// are passed to the decision methods rather than stored.
public struct CommandPaletteKeystroke: Sendable, Equatable {
    /// The hardware key code reported by the event.
    public let keyCode: UInt16
    /// The modifier flags reported by the event.
    public let modifierFlags: NSEvent.ModifierFlags
    /// The characters reported by the event (already resolved by the caller).
    public let characters: String

    /// Creates a keystroke from raw event fields.
    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
    }

    /// Whether this shortcut must be consumed while the palette is visible.
    ///
    /// Escape (key code 53 with no modifiers) always dismisses the palette and
    /// must not leak through to the underlying terminal or browser content. The
    /// `modifierFlags` passed by the caller are expected to already be
    /// device-independent and normalized, matching the previous inline policy.
    /// Clipboard/undo command shortcuts and arrow/delete editing commands are
    /// allowed through so palette text editing keeps working.
    public func shouldConsumeWhilePaletteVisible(isPaletteVisible: Bool) -> Bool {
        guard isPaletteVisible else { return false }

        // Escape dismisses the palette, and must not leak through to the
        // underlying terminal or browser content.
        if modifierFlags.isEmpty, keyCode == 53 {
            return true
        }

        guard modifierFlags.contains(.command) else { return false }

        let normalizedChars = characters.lowercased()

        if modifierFlags == [.command] {
            if normalizedChars == "a"
                || normalizedChars == "c"
                || normalizedChars == "v"
                || normalizedChars == "x"
                || normalizedChars == "z"
                || normalizedChars == "y" {
                return false
            }

            switch keyCode {
            case 51, 117, 123, 124:
                return false
            default:
                break
            }
        }

        if modifierFlags == [.command, .shift], normalizedChars == "z" {
            return false
        }

        return true
    }

    /// Whether a Return/Enter keystroke should submit the palette in `mode`.
    ///
    /// Return (36) and the numeric-keypad Enter (76) submit when no modifiers
    /// are held. Shift+Return submits in every mode except the
    /// `workspace_description_input` mode, where it inserts a newline instead.
    public func shouldSubmitWithReturn(mode: String) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        let normalizedFlags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if normalizedFlags.isEmpty {
            return true
        }
        if normalizedFlags == [.shift] {
            return mode != "workspace_description_input"
        }
        return false
    }
}
