import AppKit

/// Converts native key events to the DOM and virtual-key fields expected by
/// Chrome DevTools Protocol.
struct ChromiumKeyMapping: Sendable {
    struct Value: Sendable {
        let key: String
        let code: String
        let text: String?
        let modifiers: Int
        let windowsVirtualKeyCode: Int
    }

    private let altBit = 1
    private let controlBit = 2
    private let commandBit = 4
    private let shiftBit = 8

    func map(_ event: NSEvent) -> Value {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.option) { modifiers |= altBit }
        if flags.contains(.control) { modifiers |= controlBit }
        if flags.contains(.command) { modifiers |= commandBit }
        if flags.contains(.shift) { modifiers |= shiftBit }
        return Value(
            key: keyName(for: event),
            code: codeName(for: event),
            text: event.characters.flatMap { $0.isEmpty ? nil : $0 },
            modifiers: modifiers,
            windowsVirtualKeyCode: windowsVirtualKeyCode(for: event)
        )
    }

    private func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 49: return " "
        case 51: return "Backspace"
        case 53: return "Escape"
        case 117: return "Delete"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return event.characters ?? "Unidentified"
        }
    }

    /// Maps macOS virtual key codes to the DOM `KeyboardEvent.code` values.
    /// Unknown physical keys deliberately use `Unidentified`; synthesizing a
    /// `Key…` value for punctuation or function keys changes page behavior.
    private func codeName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 0: return "KeyA"
        case 1: return "KeyS"
        case 2: return "KeyD"
        case 3: return "KeyF"
        case 4: return "KeyH"
        case 5: return "KeyG"
        case 6: return "KeyZ"
        case 7: return "KeyX"
        case 8: return "KeyC"
        case 9: return "KeyV"
        case 11: return "KeyB"
        case 12: return "KeyQ"
        case 13: return "KeyW"
        case 14: return "KeyE"
        case 15: return "KeyR"
        case 16: return "KeyY"
        case 17: return "KeyT"
        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 22: return "Digit6"
        case 23: return "Digit5"
        case 24: return "Equal"
        case 25: return "Digit9"
        case 26: return "Digit7"
        case 27: return "Minus"
        case 28: return "Digit8"
        case 29: return "Digit0"
        case 30: return "BracketRight"
        case 31: return "KeyO"
        case 32: return "KeyU"
        case 33: return "BracketLeft"
        case 34: return "KeyI"
        case 35: return "KeyP"
        case 36: return "Enter"
        case 37: return "KeyL"
        case 38: return "KeyJ"
        case 39: return "Quote"
        case 40: return "KeyK"
        case 41: return "Semicolon"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 44: return "Slash"
        case 45: return "KeyN"
        case 46: return "KeyM"
        case 47: return "Period"
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "Backquote"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 54, 55: return "Meta"
        case 56, 60: return "Shift"
        case 57: return "CapsLock"
        case 58, 61: return "Alt"
        case 59, 62: return "Control"
        case 64: return "F17"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "Delete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PageDown"
        case 122: return "F1"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return "Unidentified"
        }
    }

    /// Maps macOS virtual key codes to Chromium's Windows-compatible VK field.
    /// The value is used for legacy `KeyboardEvent.keyCode`/`which` consumers;
    /// macOS key codes must not be forwarded directly.
    private func windowsVirtualKeyCode(for event: NSEvent) -> Int {
        switch event.keyCode {
        case 0: return 0x41
        case 1: return 0x53
        case 2: return 0x44
        case 3: return 0x46
        case 4: return 0x48
        case 5: return 0x47
        case 6: return 0x5A
        case 7: return 0x58
        case 8: return 0x43
        case 9: return 0x56
        case 11: return 0x42
        case 12: return 0x51
        case 13: return 0x57
        case 14: return 0x45
        case 15: return 0x52
        case 16: return 0x59
        case 17: return 0x54
        case 18: return 0x31
        case 19: return 0x32
        case 20: return 0x33
        case 21: return 0x34
        case 22: return 0x36
        case 23: return 0x35
        case 24: return 0xBB
        case 25: return 0x39
        case 26: return 0x37
        case 27: return 0xBD
        case 28: return 0x38
        case 29: return 0x30
        case 30: return 0xDD
        case 31: return 0x4F
        case 32: return 0x55
        case 33: return 0xDB
        case 34: return 0x49
        case 35: return 0x50
        case 36, 76: return 0x0D
        case 37: return 0x4C
        case 38: return 0x4A
        case 39: return 0xDE
        case 40: return 0x4B
        case 41: return 0xBA
        case 42: return 0xDC
        case 43: return 0xBC
        case 44: return 0xBF
        case 45: return 0x4E
        case 46: return 0x4D
        case 47: return 0xBE
        case 48: return 0x09
        case 49: return 0x20
        case 50: return 0xC0
        case 51: return 0x08
        case 53: return 0x1B
        case 54: return 0x5B
        case 55: return 0x5C
        case 56: return 0xA0
        case 57: return 0x14
        case 58: return 0xA4
        case 59: return 0xA2
        case 60: return 0xA1
        case 61: return 0xA5
        case 62: return 0xA3
        case 96: return 0x74
        case 97: return 0x75
        case 98: return 0x76
        case 99: return 0x72
        case 100: return 0x77
        case 101: return 0x78
        case 103: return 0x7A
        case 105: return 0x7C
        case 106: return 0x7F
        case 107: return 0x7D
        case 109: return 0x79
        case 111: return 0x7B
        case 113: return 0x7E
        case 114: return 0x2C
        case 115: return 0x24
        case 116: return 0x21
        case 117: return 0x2E
        case 118: return 0x73
        case 119: return 0x23
        case 120: return 0x71
        case 121: return 0x22
        case 122: return 0x70
        case 123: return 0x25
        case 124: return 0x27
        case 125: return 0x28
        case 126: return 0x26
        default: return 0
        }
    }
}
