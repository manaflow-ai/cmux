/// A USB HID usage as rd sends it: `page << 16 | id` (cmux-rd-proto
/// `InputEvent::Key`). Keys use the keyboard page (7), so the meaning does
/// not depend on the phone's keyboard layout.
public struct HidUsage: RawRepresentable, Hashable, Sendable {
    public static let keyboardPage: UInt32 = 7

    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// A keyboard-page usage id (`UIKeyboardHIDUsage` raw values are these).
    public init(keyboard id: UInt32) {
        rawValue = Self.keyboardPage << 16 | (id & 0xffff)
    }

    public var page: UInt32 { rawValue >> 16 }
    public var id: UInt32 { rawValue & 0xffff }
    public var isKeyboard: Bool { page == Self.keyboardPage }
    /// Control, shift, option (alt) and command (GUI), left and right.
    public var isModifier: Bool { isKeyboard && (0xE0...0xE7).contains(id) }

    public static let returnKey = HidUsage(keyboard: 0x28)
    public static let escape = HidUsage(keyboard: 0x29)
    public static let backspace = HidUsage(keyboard: 0x2A)
    public static let tab = HidUsage(keyboard: 0x2B)
    public static let space = HidUsage(keyboard: 0x2C)
    public static let deleteForward = HidUsage(keyboard: 0x4C)
    public static let home = HidUsage(keyboard: 0x4A)
    public static let pageUp = HidUsage(keyboard: 0x4B)
    public static let end = HidUsage(keyboard: 0x4D)
    public static let pageDown = HidUsage(keyboard: 0x4E)
    public static let right = HidUsage(keyboard: 0x4F)
    public static let left = HidUsage(keyboard: 0x50)
    public static let down = HidUsage(keyboard: 0x51)
    public static let up = HidUsage(keyboard: 0x52)
    public static let leftControl = HidUsage(keyboard: 0xE0)
    public static let leftShift = HidUsage(keyboard: 0xE1)
    public static let leftOption = HidUsage(keyboard: 0xE2)
    public static let leftCommand = HidUsage(keyboard: 0xE3)
    public static let rightControl = HidUsage(keyboard: 0xE4)
    public static let rightShift = HidUsage(keyboard: 0xE5)
    public static let rightOption = HidUsage(keyboard: 0xE6)
    public static let rightCommand = HidUsage(keyboard: 0xE7)

    /// F1 to F12.
    public static func function(_ number: Int) -> HidUsage? {
        guard (1...12).contains(number) else { return nil }
        return HidUsage(keyboard: 0x3A + UInt32(number - 1))
    }

    /// The usage of an ASCII letter or digit (layout independent position of
    /// the US key that types it).
    public static func key(for character: Character) -> HidUsage? {
        guard let ascii = character.lowercased().unicodeScalars.first?.value, character.unicodeScalars.count == 1 else { return nil }
        switch ascii {
        case 0x61...0x7A: return HidUsage(keyboard: 0x04 + ascii - 0x61)
        case 0x31...0x39: return HidUsage(keyboard: 0x1E + ascii - 0x31)
        case 0x30: return HidUsage(keyboard: 0x27)
        default: return nil
        }
    }
}
