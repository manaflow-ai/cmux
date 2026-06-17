#if canImport(AppKit)
import AppKit

/// Translates macOS key events into X11 keysyms for RFB `KeyEvent` messages.
public enum VNCKeyMap {
    /// Special keys identified by hardware `keyCode` (layout-independent).
    private static let specialKeysyms: [UInt16: UInt32] = [
        36: 0xFF0D,  // Return
        76: 0xFF8D,  // Keypad Enter
        48: 0xFF09,  // Tab
        51: 0xFF08,  // Delete (Backspace)
        53: 0xFF1B,  // Escape
        117: 0xFFFF, // Forward Delete
        115: 0xFF50, // Home
        119: 0xFF57, // End
        116: 0xFF55, // Page Up
        121: 0xFF56, // Page Down
        123: 0xFF51, // Left
        124: 0xFF53, // Right
        125: 0xFF54, // Down
        126: 0xFF52, // Up
        122: 0xFFBE, // F1
        120: 0xFFBF, // F2
        99: 0xFFC0,  // F3
        118: 0xFFC1, // F4
        96: 0xFFC2,  // F5
        97: 0xFFC3,  // F6
        98: 0xFFC4,  // F7
        100: 0xFFC5, // F8
        101: 0xFFC6, // F9
        109: 0xFFC7, // F10
        103: 0xFFC8, // F11
        111: 0xFFC9, // F12
    ]

    /// Returns the keysym for a key-down/up event, or `nil` if it has no mapping.
    public static func keysym(for event: NSEvent) -> UInt32? {
        if let special = specialKeysyms[event.keyCode] {
            return special
        }
        let withModifiers = event.characters ?? ""
        let withoutModifiers = event.charactersIgnoringModifiers ?? ""
        // With Control held, `characters` is a control code; prefer the base key.
        let controlDown = event.modifierFlags.contains(.control)
        let source = (controlDown || withModifiers.isEmpty) ? withoutModifiers : withModifiers
        guard let scalar = source.unicodeScalars.first else { return nil }
        return keysym(forScalar: scalar)
    }

    static func keysym(forScalar scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        // Latin-1 maps directly; other Unicode uses the X11 0x01000000 plane.
        return value <= 0xFF ? value : (0x0100_0000 + value)
    }

    /// Keysym for a modifier flag, used on `flagsChanged`. Command maps to
    /// Super, Option to Alt, matching common server expectations.
    public static func modifierKeysym(for flag: NSEvent.ModifierFlags) -> UInt32? {
        switch flag {
        case .shift: return 0xFFE1   // Shift_L
        case .control: return 0xFFE3 // Control_L
        case .option: return 0xFFE9  // Alt_L
        case .command: return 0xFFEB // Super_L
        case .capsLock: return 0xFFE5 // Caps_Lock
        default: return nil
        }
    }

    /// The modifier flags cmux forwards, in a stable order.
    public static let trackedModifiers: [NSEvent.ModifierFlags] = [.shift, .control, .option, .command]
}
#endif
