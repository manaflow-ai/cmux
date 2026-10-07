import AppKit
import CmuxNextActions

/// Who gets a key-down.
enum KeyOwner: Equatable, CustomStringConvertible {
    /// A cmux action runs and the key is consumed.
    case action(ActionID)
    /// The focused surface gets the key (terminal, page, text field).
    case surface
    /// A panel over the window (palette, sheet) gets the key.
    case panel
    /// cmux consumes the key and runs nothing (browser-only chord elsewhere).
    case consumed
    /// The screen's primary input gets the key (R65).
    case primaryInput
    /// The key waits for a loading page's primary input (type-ahead).
    case typeAhead

    var description: String {
        switch self {
        case .action(let id): "action(\(id))"
        case .surface: "surface"
        case .panel: "panel"
        case .consumed: "consumed"
        case .primaryInput: "primaryInput"
        case .typeAhead: "typeAhead"
        }
    }
}

/// Facts about the focused surface that the focus state does not hold.
struct KeyOwnershipFacts: Equatable {
    var terminalAltScreen = false
    var terminalCopyMode = false
}

/// Key-down events for a shortcut, with the US key code AppKit reports, so
/// `characters(byApplyingModifiers:)` gives the real unshifted key.
enum KeyEvents {
    static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49,
            "`": 50, "\u{7f}": 51, "\u{1b}": 53,
        ]
        let functionKeys: [(Int, UInt16)] = [
            (NSLeftArrowFunctionKey, 123), (NSRightArrowFunctionKey, 124), (NSDownArrowFunctionKey, 125), (NSUpArrowFunctionKey, 126),
            (NSPageUpFunctionKey, 116), (NSPageDownFunctionKey, 121), (NSHomeFunctionKey, 115), (NSEndFunctionKey, 119),
            (NSDeleteFunctionKey, 117), (NSF1FunctionKey, 122), (NSF2FunctionKey, 120), (NSF3FunctionKey, 99), (NSF4FunctionKey, 118),
            (NSF5FunctionKey, 96), (NSF6FunctionKey, 97), (NSF7FunctionKey, 98), (NSF8FunctionKey, 100), (NSF9FunctionKey, 101),
            (NSF10FunctionKey, 109), (NSF11FunctionKey, 103), (NSF12FunctionKey, 111),
        ]
        for (scalar, code) in functionKeys { codes[String(UnicodeScalar(UInt32(scalar))!)] = code }
        return codes
    }()

    static func event(for shortcut: Shortcut) -> NSEvent? {
        guard let keyCode = keyCodes[shortcut.key] else { return nil }
        var flags = shortcut.modifiers
        if let scalar = shortcut.key.unicodeScalars.first, scalar.value >= 0xF700 { flags.insert([.function, .numericPad]) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                                characters: shortcut.key, charactersIgnoringModifiers: shortcut.key, isARepeat: false, keyCode: keyCode)
    }
}
