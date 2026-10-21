/// USB HID keyboard usages for a US layout: what typed text and Mac key
/// codes become on the simulator's hardware keyboard.
struct PhoneKeyboard {
    /// The key strokes that type `text`, or nil when a character has no US
    /// key (the backend then pastes the text instead).
    func strokes(for text: String) -> [PhoneKeyStroke]? {
        var strokes: [PhoneKeyStroke] = []
        for scalar in text.unicodeScalars {
            guard let stroke = stroke(for: scalar) else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    func stroke(for scalar: Unicode.Scalar) -> PhoneKeyStroke? {
        let value = scalar.value
        switch scalar {
        case "a"..."z": return PhoneKeyStroke(usage: 0x04 + value - 0x61)
        case "A"..."Z": return PhoneKeyStroke(usage: 0x04 + value - 0x41, shift: true)
        case "1"..."9": return PhoneKeyStroke(usage: 0x1E + value - 0x31)
        case "0": return PhoneKeyStroke(usage: 0x27)
        case "\n", "\r": return PhoneKeyStroke(usage: 0x28)
        case "\t": return PhoneKeyStroke(usage: 0x2B)
        case " ": return PhoneKeyStroke(usage: 0x2C)
        default: break
        }
        if let index = Self.shiftedDigits.firstIndex(of: Character(scalar)) {
            let usage: UInt32 = index == 9 ? 0x27 : 0x1E + UInt32(index)
            return PhoneKeyStroke(usage: usage, shift: true)
        }
        for (plain, shifted, usage) in Self.punctuation {
            if Character(scalar) == plain { return PhoneKeyStroke(usage: usage) }
            if Character(scalar) == shifted { return PhoneKeyStroke(usage: usage, shift: true) }
        }
        return nil
    }

    /// The HID usage for a Mac virtual key code (`NSEvent.keyCode`); nil for
    /// keys the simulator has no use for.
    func usage(forMacKeyCode code: UInt16) -> UInt32? {
        Self.macKeyCodes[code]
    }

    private static let shiftedDigits: [Character] = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
    private static let punctuation: [(Character, Character, UInt32)] = [
        ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30), ("\\", "|", 0x31),
        (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35), (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38),
    ]
    // kVK_* codes (Carbon Events.h) to HID usages.
    private static let macKeyCodes: [UInt16: UInt32] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D, 40: 0x0E,
        37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19,
        13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
        41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 117: 0x4C,
        124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
    ]
}
