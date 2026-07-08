public import Foundation

/// Translates macOS virtual key codes and characters into the Windows
/// virtual-key codes Blink expects.
///
/// The mapping covers editing/navigation keys explicitly and derives
/// alphanumeric codes from the key's characters; unknown keys fall back to 0,
/// which still delivers printable input through the event's text.
public struct ChromiumKeyTranslation: Sendable {
    /// macOS virtual key code → Windows virtual-key code for non-printable keys.
    private static let macToWindowsKeyCode: [UInt16: UInt32] = [
        0x24: 0x0D, // Return -> VK_RETURN
        0x4C: 0x0D, // Keypad Enter -> VK_RETURN
        0x30: 0x09, // Tab -> VK_TAB
        0x31: 0x20, // Space -> VK_SPACE
        0x33: 0x08, // Delete (backspace) -> VK_BACK
        0x75: 0x2E, // Forward Delete -> VK_DELETE
        0x35: 0x1B, // Escape -> VK_ESCAPE
        0x7B: 0x25, // Left Arrow -> VK_LEFT
        0x7E: 0x26, // Up Arrow -> VK_UP
        0x7C: 0x27, // Right Arrow -> VK_RIGHT
        0x7D: 0x28, // Down Arrow -> VK_DOWN
        0x73: 0x24, // Home -> VK_HOME
        0x77: 0x23, // End -> VK_END
        0x74: 0x21, // Page Up -> VK_PRIOR
        0x79: 0x22, // Page Down -> VK_NEXT
        0x7A: 0x70, // F1
        0x78: 0x71, // F2
        0x63: 0x72, // F3
        0x76: 0x73, // F4
        0x60: 0x74, // F5
        0x61: 0x75, // F6
        0x62: 0x76, // F7
        0x64: 0x77, // F8
        0x65: 0x78, // F9
        0x6D: 0x79, // F10
        0x67: 0x7A, // F11
        0x6F: 0x7B, // F12
    ]

    /// Creates a translator.
    public init() {}

    /// Returns the Windows virtual-key code for one macOS key press.
    ///
    /// - Parameters:
    ///   - macKeyCode: `NSEvent.keyCode` (macOS virtual key code).
    ///   - characters: `NSEvent.charactersIgnoringModifiers` for the event.
    /// - Returns: The `VK_*` code, or 0 when the key has no mapping.
    public func windowsKeyCode(macKeyCode: UInt16, characters: String?) -> UInt32 {
        if let mapped = Self.macToWindowsKeyCode[macKeyCode] {
            return mapped
        }
        guard let scalar = characters?.unicodeScalars.first else {
            return 0
        }
        // Windows VK codes for 0-9 and A-Z equal their ASCII uppercase values.
        if scalar.properties.isAlphabetic, scalar.isASCII {
            return UInt32(Character(scalar).uppercased().unicodeScalars.first?.value ?? 0)
        }
        if ("0"..."9").contains(Character(scalar)) {
            return scalar.value
        }
        return 0
    }

    /// Returns the text payload for a key event, or empty when the key should
    /// not produce a `Char` event (control characters and command shortcuts).
    ///
    /// - Parameters:
    ///   - characters: `NSEvent.characters` for the event.
    ///   - isCommandPressed: Whether the Command modifier was held.
    public func text(characters: String?, isCommandPressed: Bool) -> String {
        guard !isCommandPressed, let characters, let scalar = characters.unicodeScalars.first else {
            return ""
        }
        // Function/arrow keys report characters in the Unicode private-use area;
        // control characters other than return/tab must not become Char events.
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
            return ""
        }
        if scalar.value < 0x20 && scalar.value != 0x0D && scalar.value != 0x09 {
            return ""
        }
        if scalar.value == 0x7F {
            return ""
        }
        return characters
    }
}
