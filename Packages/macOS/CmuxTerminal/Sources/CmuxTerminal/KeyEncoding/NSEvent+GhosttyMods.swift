public import AppKit
public import GhosttyKit

extension NSEvent {
    /// libghostty key-event mods derived from this event's modifier flags
    /// (preserves sided modifiers; see ``NSEvent/ModifierFlags/terminalGhosttyKeyMods``).
    @inlinable
    public var terminalGhosttyKeyMods: ghostty_input_mods_e {
        modifierFlags.terminalGhosttyKeyMods
    }

    /// libghostty mouse mods derived from this event's modifier flags
    /// (normalized binding bits; see ``NSEvent/ModifierFlags/terminalGhosttyMouseMods``).
    @inlinable
    public var terminalGhosttyMouseMods: ghostty_input_mods_e {
        modifierFlags.terminalGhosttyMouseMods
    }

    /// The characters for this key event with control-character handling.
    ///
    /// When control is pressed and the event reports a single control
    /// character, the character is returned without the control modifier so
    /// Ghostty's KeyEncoder can apply its own control-character encoding.
    /// Private Use Area characters (function keys) are dropped.
    @inlinable
    public var terminalGhosttyKeyText: String? {
        guard let chars = characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if scalar.isTerminalControlCharacter {
                if flags.contains(.control) {
                    return characters(byApplyingModifiers: modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }
}
