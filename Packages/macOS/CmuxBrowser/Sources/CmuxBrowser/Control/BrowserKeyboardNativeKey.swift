/// The macOS virtual-key description for a canonical browser keyboard event.
public struct BrowserKeyboardNativeModifiers: OptionSet, Equatable, Hashable, Sendable {
    /// The raw modifier bitset used by the browser input adapter.
    public let rawValue: UInt8

    /// Creates a modifier bitset from its raw value.
    /// - Parameter rawValue: Encoded modifier bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Shift is held for the event.
    public static let shift = Self(rawValue: 1 << 0)
    /// Control is held for the event.
    public static let control = Self(rawValue: 1 << 1)
    /// Option/Alt is held for the event.
    public static let option = Self(rawValue: 1 << 2)
    /// Command/Meta is held for the event.
    public static let command = Self(rawValue: 1 << 3)
    /// The key is on the numeric keypad.
    public static let numericPad = Self(rawValue: 1 << 4)
    /// Caps Lock is held for the event.
    public static let capsLock = Self(rawValue: 1 << 5)
    /// The Function key is held for the event.
    public static let function = Self(rawValue: 1 << 6)
}

/// A platform-neutral native key descriptor for the macOS keyboard adapter.
public struct BrowserKeyboardNativeKey: Equatable, Sendable {
    /// macOS virtual-key code for the physical key.
    public let keyCode: UInt16

    /// DOM keyboard location (`0` for the standard row, `3` for the keypad).
    public let location: Int

    /// Modifier flags intrinsic to this key event (for example Shift for `A`).
    public let modifiers: BrowserKeyboardNativeModifiers

    /// The modifier represented by this key itself, when it is a modifier key.
    /// This lets the AppKit adapter emit `flagsChanged` and retain the state.
    public let modifierKey: BrowserKeyboardNativeModifiers?

    /// Unicode characters to attach to the native event, when it produces text.
    public let characters: String?

    /// Characters produced when modifier flags are ignored.
    public let charactersIgnoringModifiers: String?

    init(
        keyCode: UInt16,
        location: Int = 0,
        modifiers: BrowserKeyboardNativeModifiers = [],
        modifierKey: BrowserKeyboardNativeModifiers? = nil,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil
    ) {
        self.keyCode = keyCode
        self.location = location
        self.modifiers = modifiers
        self.modifierKey = modifierKey
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }
}

extension BrowserKeyboardEvent {
    /// Resolves this W3C/Playwright key into a macOS native key descriptor.
    ///
    /// The mapping is intentionally kept in the browser package, next to the
    /// canonical DOM vocabulary, so every host adapter uses one source of
    /// truth. `nil` means the caller supplied an opaque key value that AppKit
    /// cannot represent; such values may use the legacy page-event fallback.
    public var nativeKey: BrowserKeyboardNativeKey? {
        let normalizedCode = code.lowercased()
        switch normalizedCode {
        case "arrowleft", "left":
            return .init(keyCode: 123, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}")
        case "arrowright", "right":
            return .init(keyCode: 124, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}")
        case "arrowdown", "down":
            return .init(keyCode: 125, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}")
        case "arrowup", "up":
            return .init(keyCode: 126, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}")
        case "enter", "return":
            return BrowserKeyboardNativeKey.special(keyCode: 36, character: "\r")
        case "numpadenter":
            return .init(keyCode: 76, location: 3, modifiers: .numericPad)
        case "tab":
            return BrowserKeyboardNativeKey.special(keyCode: 48, character: "\t")
        case "escape", "esc":
            return BrowserKeyboardNativeKey.special(keyCode: 53, character: "\u{1b}")
        case "backspace":
            return BrowserKeyboardNativeKey.special(keyCode: 51, character: "\u{8}")
        case "delete":
            return BrowserKeyboardNativeKey.special(keyCode: 117, character: "\u{F728}")
        case "home":
            return BrowserKeyboardNativeKey.special(keyCode: 115, character: "\u{F729}")
        case "end":
            return BrowserKeyboardNativeKey.special(keyCode: 119, character: "\u{F72B}")
        case "pageup":
            return BrowserKeyboardNativeKey.special(keyCode: 116, character: "\u{F72C}")
        case "pagedown":
            return BrowserKeyboardNativeKey.special(keyCode: 121, character: "\u{F72D}")
        case "insert":
            return BrowserKeyboardNativeKey.special(keyCode: 114, character: "\u{F727}")
        case "space":
            return .init(
                keyCode: 49,
                characters: " ",
                charactersIgnoringModifiers: " "
            )
        case "shiftleft":
            return BrowserKeyboardNativeKey.modifier(keyCode: 56, location: 1, flag: .shift)
        case "shiftright":
            return BrowserKeyboardNativeKey.modifier(keyCode: 60, location: 2, flag: .shift)
        case "controlleft":
            return BrowserKeyboardNativeKey.modifier(keyCode: 59, location: 1, flag: .control)
        case "controlright":
            return BrowserKeyboardNativeKey.modifier(keyCode: 62, location: 2, flag: .control)
        case "altleft", "optionleft":
            return BrowserKeyboardNativeKey.modifier(keyCode: 58, location: 1, flag: .option)
        case "altright", "optionright":
            return BrowserKeyboardNativeKey.modifier(keyCode: 61, location: 2, flag: .option)
        case "metaleft", "commandleft":
            return BrowserKeyboardNativeKey.modifier(keyCode: 55, location: 1, flag: .command)
        case "metaright", "commandright":
            return BrowserKeyboardNativeKey.modifier(keyCode: 54, location: 2, flag: .command)
        case "capslock":
            return BrowserKeyboardNativeKey.modifier(keyCode: 57, flag: .capsLock)
        case "numpaddivide":
            return BrowserKeyboardNativeKey.keypad(keyCode: 75, character: "/")
        case "numpadmultiply":
            return BrowserKeyboardNativeKey.keypad(keyCode: 67, character: "*")
        case "numpadsubtract":
            return BrowserKeyboardNativeKey.keypad(keyCode: 78, character: "-")
        case "numpadadd":
            return BrowserKeyboardNativeKey.keypad(keyCode: 69, character: "+")
        case "numpaddecimal":
            return BrowserKeyboardNativeKey.keypad(keyCode: 65)
        case "numpad0":
            return BrowserKeyboardNativeKey.keypad(keyCode: 82)
        case "numpad1":
            return BrowserKeyboardNativeKey.keypad(keyCode: 83)
        case "numpad2":
            return BrowserKeyboardNativeKey.keypad(keyCode: 84)
        case "numpad3":
            return BrowserKeyboardNativeKey.keypad(keyCode: 85)
        case "numpad4":
            return BrowserKeyboardNativeKey.keypad(keyCode: 86)
        case "numpad5":
            return BrowserKeyboardNativeKey.keypad(keyCode: 87)
        case "numpad6":
            return BrowserKeyboardNativeKey.keypad(keyCode: 88)
        case "numpad7":
            return BrowserKeyboardNativeKey.keypad(keyCode: 89)
        case "numpad8":
            return BrowserKeyboardNativeKey.keypad(keyCode: 91)
        case "numpad9":
            return BrowserKeyboardNativeKey.keypad(keyCode: 92)
        case "f1": return BrowserKeyboardNativeKey.special(keyCode: 122, character: "\u{F704}")
        case "f2": return BrowserKeyboardNativeKey.special(keyCode: 120, character: "\u{F705}")
        case "f3": return BrowserKeyboardNativeKey.special(keyCode: 99, character: "\u{F706}")
        case "f4": return BrowserKeyboardNativeKey.special(keyCode: 118, character: "\u{F707}")
        case "f5": return BrowserKeyboardNativeKey.special(keyCode: 96, character: "\u{F708}")
        case "f6": return BrowserKeyboardNativeKey.special(keyCode: 97, character: "\u{F709}")
        case "f7": return BrowserKeyboardNativeKey.special(keyCode: 98, character: "\u{F70A}")
        case "f8": return BrowserKeyboardNativeKey.special(keyCode: 100, character: "\u{F70B}")
        case "f9": return BrowserKeyboardNativeKey.special(keyCode: 101, character: "\u{F70C}")
        case "f10": return BrowserKeyboardNativeKey.special(keyCode: 109, character: "\u{F70D}")
        case "f11": return BrowserKeyboardNativeKey.special(keyCode: 103, character: "\u{F70E}")
        case "f12": return BrowserKeyboardNativeKey.special(keyCode: 111, character: "\u{F70F}")
        default:
            return BrowserKeyboardNativeKey.nativePrintableKey(code: normalizedCode, key: key)
        }
    }
}

fileprivate extension BrowserKeyboardNativeKey {
    static func special(keyCode: UInt16, character: String) -> BrowserKeyboardNativeKey {
        .init(
            keyCode: keyCode,
            characters: character,
            charactersIgnoringModifiers: character
        )
    }

    static func modifier(
        keyCode: UInt16,
        location: Int = 0,
        flag: BrowserKeyboardNativeModifiers
    ) -> BrowserKeyboardNativeKey {
        .init(
            keyCode: keyCode,
            location: location,
            modifiers: flag,
            modifierKey: flag
        )
    }

    static func keypad(
        keyCode: UInt16,
        character: String? = nil
    ) -> BrowserKeyboardNativeKey {
        .init(
            keyCode: keyCode,
            location: 3,
            modifiers: .numericPad,
            characters: character,
            charactersIgnoringModifiers: character
        )
    }

    static func nativePrintableKey(code: String, key: String) -> BrowserKeyboardNativeKey? {
        let base: (keyCode: UInt16, character: String)?
        switch code {
        case "keya": base = (0, "a")
        case "keyb": base = (11, "b")
        case "keyc": base = (8, "c")
        case "keyd": base = (2, "d")
        case "keye": base = (14, "e")
        case "keyf": base = (3, "f")
        case "keyg": base = (5, "g")
        case "keyh": base = (4, "h")
        case "keyi": base = (34, "i")
        case "keyj": base = (38, "j")
        case "keyk": base = (40, "k")
        case "keyl": base = (37, "l")
        case "keym": base = (46, "m")
        case "keyn": base = (45, "n")
        case "keyo": base = (31, "o")
        case "keyp": base = (35, "p")
        case "keyq": base = (12, "q")
        case "keyr": base = (15, "r")
        case "keys": base = (1, "s")
        case "keyt": base = (17, "t")
        case "keyu": base = (32, "u")
        case "keyv": base = (9, "v")
        case "keyw": base = (13, "w")
        case "keyx": base = (7, "x")
        case "keyy": base = (16, "y")
        case "keyz": base = (6, "z")
        case "digit0": base = (29, "0")
        case "digit1": base = (18, "1")
        case "digit2": base = (19, "2")
        case "digit3": base = (20, "3")
        case "digit4": base = (21, "4")
        case "digit5": base = (23, "5")
        case "digit6": base = (22, "6")
        case "digit7": base = (26, "7")
        case "digit8": base = (28, "8")
        case "digit9": base = (25, "9")
        case "backquote": base = (50, "`")
        case "minus": base = (27, "-")
        case "equal": base = (24, "=")
        case "bracketleft": base = (33, "[")
        case "bracketright": base = (30, "]")
        case "backslash": base = (42, "\\")
        case "semicolon": base = (41, ";")
        case "quote": base = (39, "'")
        case "comma": base = (43, ",")
        case "period": base = (47, ".")
        case "slash": base = (44, "/")
        default:
            return Self.nativePrintableCharacter(key)
        }
        guard let base else { return nil }
        return Self.printable(key: key, base: base.character, keyCode: base.keyCode)
    }

    static func nativePrintableCharacter(_ key: String) -> BrowserKeyboardNativeKey? {
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first,
              scalar.isASCII else { return nil }
        switch scalar.value {
        case 65...90, 97...122:
            let keyCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
            let lowercaseScalar = scalar.value >= 65 && scalar.value <= 90
                ? scalar.value + 32
                : scalar.value
            guard let baseScalar = UnicodeScalar(lowercaseScalar) else { return nil }
            let base = String(baseScalar)
            return .printable(key: key, base: base, keyCode: keyCodes[Int(lowercaseScalar - 97)])
        case 48...57:
            let keyCodes: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
            return .printable(key: key, base: key, keyCode: keyCodes[Int(scalar.value - 48)])
        default:
            switch key {
            case "`", "~": return .printable(key: key, base: "`", keyCode: 50)
            case "-", "_": return .printable(key: key, base: "-", keyCode: 27)
            case "=", "+": return .printable(key: key, base: "=", keyCode: 24)
            case "[", "{": return .printable(key: key, base: "[", keyCode: 33)
            case "]", "}": return .printable(key: key, base: "]", keyCode: 30)
            case "\\", "|": return .printable(key: key, base: "\\", keyCode: 42)
            case ";", ":": return .printable(key: key, base: ";", keyCode: 41)
            case "'", "\"": return .printable(key: key, base: "'", keyCode: 39)
            case ",", "<": return .printable(key: key, base: ",", keyCode: 43)
            case ".", ">": return .printable(key: key, base: ".", keyCode: 47)
            case "/", "?": return .printable(key: key, base: "/", keyCode: 44)
            default: return nil
            }
        }
    }

    static func printable(
        key: String,
        base: String,
        keyCode: UInt16
    ) -> BrowserKeyboardNativeKey {
        let requiresShift = key != base
        return .init(
            keyCode: keyCode,
            modifiers: requiresShift ? .shift : [],
            characters: key,
            charactersIgnoringModifiers: base
        )
    }
}
