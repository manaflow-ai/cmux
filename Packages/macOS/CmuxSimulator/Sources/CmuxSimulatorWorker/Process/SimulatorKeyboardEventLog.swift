import Foundation

/// Produces privacy-preserving labels for keyboard action-log entries.
///
/// The printable-key policy matches serve-sim commit
/// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 (Apache License 2.0), extended
/// for the non-US backslash and keypad-equals usages accepted by this client.
enum SimulatorKeyboardEventLog {
    static func summary(for usage: UInt32) -> String {
        if isPrintable(usage) { return "character" }
        return controlLabels[usage] ?? "control"
    }

    static func isPrintable(_ usage: UInt32) -> Bool {
        switch usage {
        case 0x04...0x27,
             0x2C...0x38,
             0x54...0x57,
             0x59...0x64,
             0x67:
            true
        default:
            false
        }
    }

    private static let controlLabels: [UInt32: String] = [
        0x28: "Enter",
        0x29: "Escape",
        0x2A: "Backspace",
        0x2B: "Tab",
        0x39: "CapsLock",
        0x3A: "F1",
        0x3B: "F2",
        0x3C: "F3",
        0x3D: "F4",
        0x3E: "F5",
        0x3F: "F6",
        0x40: "F7",
        0x41: "F8",
        0x42: "F9",
        0x43: "F10",
        0x44: "F11",
        0x45: "F12",
        0x46: "PrintScreen",
        0x47: "ScrollLock",
        0x48: "Pause",
        0x49: "Insert",
        0x4A: "Home",
        0x4B: "PageUp",
        0x4C: "Delete",
        0x4D: "End",
        0x4E: "PageDown",
        0x4F: "ArrowRight",
        0x50: "ArrowLeft",
        0x51: "ArrowDown",
        0x52: "ArrowUp",
        0x53: "NumLock",
        0x58: "NumpadEnter",
        0x65: "Application",
        0x66: "Power",
        0x68: "F13",
        0x69: "F14",
        0x6A: "F15",
        0x6B: "F16",
        0x6C: "F17",
        0x6D: "F18",
        0x6E: "F19",
        0x6F: "F20",
        0x70: "F21",
        0x71: "F22",
        0x72: "F23",
        0x73: "F24",
        0x7A: "Undo",
        0x7B: "Cut",
        0x7C: "Copy",
        0x7D: "Paste",
        0x7E: "Find",
        0x7F: "Mute",
        0x80: "VolumeUp",
        0x81: "VolumeDown",
        0xE0: "ControlLeft",
        0xE1: "ShiftLeft",
        0xE2: "OptionLeft",
        0xE3: "CommandLeft",
        0xE4: "ControlRight",
        0xE5: "ShiftRight",
        0xE6: "OptionRight",
        0xE7: "CommandRight",
    ]
}
