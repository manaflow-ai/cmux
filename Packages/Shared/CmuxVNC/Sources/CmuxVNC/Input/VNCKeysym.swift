import Foundation

/// An X11 keysym, the key identifier of RFB `KeyEvent`.
public struct VNCKeysym: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let backspace = VNCKeysym(rawValue: 0xFF08)
    public static let tab = VNCKeysym(rawValue: 0xFF09)
    public static let returnKey = VNCKeysym(rawValue: 0xFF0D)
    public static let escape = VNCKeysym(rawValue: 0xFF1B)
    public static let space = VNCKeysym(rawValue: 0x20)
    public static let deleteForward = VNCKeysym(rawValue: 0xFFFF)
    public static let home = VNCKeysym(rawValue: 0xFF50)
    public static let left = VNCKeysym(rawValue: 0xFF51)
    public static let up = VNCKeysym(rawValue: 0xFF52)
    public static let right = VNCKeysym(rawValue: 0xFF53)
    public static let down = VNCKeysym(rawValue: 0xFF54)
    public static let pageUp = VNCKeysym(rawValue: 0xFF55)
    public static let pageDown = VNCKeysym(rawValue: 0xFF56)
    public static let end = VNCKeysym(rawValue: 0xFF57)
    public static let insert = VNCKeysym(rawValue: 0xFF63)
    public static let shift = VNCKeysym(rawValue: 0xFFE1)
    public static let shiftRight = VNCKeysym(rawValue: 0xFFE2)
    public static let control = VNCKeysym(rawValue: 0xFFE3)
    public static let controlRight = VNCKeysym(rawValue: 0xFFE4)
    public static let capsLock = VNCKeysym(rawValue: 0xFFE5)
    /// Option on a Mac host, Alt elsewhere.
    public static let option = VNCKeysym(rawValue: 0xFFE9)
    public static let optionRight = VNCKeysym(rawValue: 0xFFEA)
    /// Command on a Mac host, the Windows/Super key elsewhere.
    public static let command = VNCKeysym(rawValue: 0xFFEB)
    public static let commandRight = VNCKeysym(rawValue: 0xFFEC)

    /// F1 to F24.
    public static func function(_ number: Int) -> VNCKeysym {
        VNCKeysym(rawValue: 0xFFBE + UInt32(max(1, min(24, number)) - 1))
    }

    /// The keysym for a typed character: Latin-1 directly, other Unicode in
    /// the 0x01000000 plane, controls as their named keys.
    public init(character: Character) {
        if character == "\n" || character == "\r" || character == "\r\n" {
            self = .returnKey
            return
        }
        if character == "\t" {
            self = .tab
            return
        }
        let value = character.unicodeScalars.first?.value ?? 0x3F
        self.init(rawValue: value <= 0xFF ? value : 0x0100_0000 | value)
    }

    /// The keysym of a physical key by USB HID usage (keyboard page 7,
    /// `0x07 << 16 | id` or the bare id), as on a US layout; nil for keys
    /// RFB has no keysym for.
    public init?(hidUsage: UInt32) {
        let page = hidUsage >> 16
        guard page == 0 || page == 7 else { return nil }
        let id = hidUsage & 0xFFFF
        switch id {
        case 0x04 ... 0x1D: self.init(rawValue: 0x61 + id - 0x04)
        case 0x1E ... 0x26: self.init(rawValue: 0x31 + id - 0x1E)
        case 0x27: self.init(rawValue: 0x30)
        case 0x3A ... 0x45: self = .function(Int(id - 0x3A) + 1)
        case 0x68 ... 0x73: self = .function(Int(id - 0x68) + 13)
        case 0x59 ... 0x61: self.init(rawValue: 0xFFB1 + id - 0x59)
        default:
            guard let raw = Self.hidTable[id] else { return nil }
            self.init(rawValue: raw)
        }
    }

    private static let hidTable: [UInt32: UInt32] = [
        0x28: 0xFF0D, 0x29: 0xFF1B, 0x2A: 0xFF08, 0x2B: 0xFF09, 0x2C: 0x20,
        0x2D: 0x2D, 0x2E: 0x3D, 0x2F: 0x5B, 0x30: 0x5D, 0x31: 0x5C, 0x32: 0x5C,
        0x33: 0x3B, 0x34: 0x27, 0x35: 0x60, 0x36: 0x2C, 0x37: 0x2E, 0x38: 0x2F,
        0x39: 0xFFE5, 0x46: 0xFF61, 0x47: 0xFF14, 0x48: 0xFF13, 0x49: 0xFF63,
        0x4A: 0xFF50, 0x4B: 0xFF55, 0x4C: 0xFFFF, 0x4D: 0xFF57, 0x4E: 0xFF56,
        0x4F: 0xFF53, 0x50: 0xFF51, 0x51: 0xFF54, 0x52: 0xFF52, 0x53: 0xFF7F,
        0x54: 0xFFAF, 0x55: 0xFFAA, 0x56: 0xFFAD, 0x57: 0xFFAB, 0x58: 0xFF8D,
        0x62: 0xFFB0, 0x63: 0xFFAE, 0x64: 0x3C, 0x67: 0xFFBD, 0x75: 0xFF6A,
        0xE0: 0xFFE3, 0xE1: 0xFFE1, 0xE2: 0xFFE9, 0xE3: 0xFFEB,
        0xE4: 0xFFE4, 0xE5: 0xFFE2, 0xE6: 0xFFEA, 0xE7: 0xFFEC,
    ]
}

/// RFB pointer buttons (bit per button; 4 to 7 are the wheel).
public struct VNCButtons: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = VNCButtons(rawValue: 1 << 0)
    public static let middle = VNCButtons(rawValue: 1 << 1)
    public static let right = VNCButtons(rawValue: 1 << 2)
    public static let wheelUp = VNCButtons(rawValue: 1 << 3)
    public static let wheelDown = VNCButtons(rawValue: 1 << 4)
    public static let wheelLeft = VNCButtons(rawValue: 1 << 5)
    public static let wheelRight = VNCButtons(rawValue: 1 << 6)
}
