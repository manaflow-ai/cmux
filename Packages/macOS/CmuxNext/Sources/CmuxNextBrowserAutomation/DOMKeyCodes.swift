import AppKit

/// DOM `KeyboardEvent.code` names to macOS virtual key codes (US layout) and
/// the characters AppKit attaches to named keys.
nonisolated enum DOMKeyCodes {
    static let virtualKey: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        let letters: [(String, UInt16)] = [
            ("A", 0x00), ("S", 0x01), ("D", 0x02), ("F", 0x03), ("H", 0x04), ("G", 0x05), ("Z", 0x06), ("X", 0x07),
            ("C", 0x08), ("V", 0x09), ("B", 0x0B), ("Q", 0x0C), ("W", 0x0D), ("E", 0x0E), ("R", 0x0F), ("Y", 0x10),
            ("T", 0x11), ("O", 0x1F), ("U", 0x20), ("I", 0x22), ("P", 0x23), ("L", 0x25), ("J", 0x26), ("K", 0x28),
            ("N", 0x2D), ("M", 0x2E),
        ]
        for (letter, code) in letters { map["Key\(letter)"] = code }
        let digits: [UInt16] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (digit, code) in digits.enumerated() { map["Digit\(digit)"] = code }
        let pad: [UInt16] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (digit, code) in pad.enumerated() { map["Numpad\(digit)"] = code }
        let function: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (index, code) in function.enumerated() { map["F\(index + 1)"] = code }
        let named: [String: UInt16] = [
            "Equal": 0x18, "Minus": 0x1B, "BracketRight": 0x1E, "BracketLeft": 0x21, "Quote": 0x27,
            "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "Period": 0x2F, "Backquote": 0x32,
            "Enter": 0x24, "Tab": 0x30, "Space": 0x31, "Backspace": 0x33, "Escape": 0x35,
            "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A,
            "ControlLeft": 0x3B, "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E,
            "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumpadDivide": 0x4B,
            "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51,
            "Insert": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
            "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
        ]
        map.merge(named) { first, _ in first }
        return map
    }()

    static let modifierFlag: [String: NSEvent.ModifierFlags] = [
        "ShiftLeft": .shift, "ShiftRight": .shift, "ControlLeft": .control, "ControlRight": .control,
        "AltLeft": .option, "AltRight": .option, "MetaLeft": .command, "MetaRight": .command, "CapsLock": .capsLock,
    ]

    private static func function(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }

    /// Characters AppKit puts on named keys (NSEvent function-key range).
    static let namedCharacters: [String: String] = {
        var map: [String: String] = [
            "Enter": "\r", "Tab": "\t", "Backspace": "\u{7F}", "Escape": "\u{1B}", " ": " ",
            "ArrowUp": function(0xF700), "ArrowDown": function(0xF701), "ArrowLeft": function(0xF702),
            "ArrowRight": function(0xF703), "Insert": function(0xF746), "Delete": function(0xF728),
            "Home": function(0xF729), "End": function(0xF72B), "PageUp": function(0xF72C), "PageDown": function(0xF72D),
        ]
        for index in 1...12 { map["F\(index)"] = function(0xF703 + index) }
        return map
    }()

    static let unshiftedSymbol: [String: String] = [
        "Equal": "=", "Minus": "-", "BracketRight": "]", "BracketLeft": "[", "Quote": "'", "Semicolon": ";",
        "Backslash": "\\", "Comma": ",", "Slash": "/", "Period": ".", "Backquote": "`", "Space": " ",
    ]

    static let functionKeys: Set<String> = [
        "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "Home", "End", "PageUp", "PageDown", "Delete", "Insert",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ]

    static let numericPad: Set<String> = Set((0...9).map { "Numpad\($0)" }).union([
        "NumpadDecimal", "NumpadMultiply", "NumpadAdd", "NumpadDivide", "NumpadEnter", "NumpadSubtract", "NumpadEqual",
        "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp",
    ])

    /// Meta shortcuts WebKit handles as editing commands.
    static let editingCommands: [String: String] = [
        "a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:", "z": "undo:",
    ]

    /// The `code` of a key given without one (`"a"`, `"Enter"`, `"#"`).
    static func code(forKey key: String) -> String? {
        if virtualKey[key] != nil { return key }
        if key == " " { return "Space" }
        guard key.count == 1, let scalar = key.lowercased().unicodeScalars.first else { return nil }
        if (97...122).contains(scalar.value) { return "Key\(key.uppercased())" }
        if (48...57).contains(scalar.value) { return "Digit\(key)" }
        if let match = unshiftedSymbol.first(where: { $0.value == key }) { return match.key }
        return shiftedSymbol[key]
    }

    /// Whether typing `key` on a US layout holds Shift (`"A"`, `"#"`).
    static func needsShift(_ key: String) -> Bool {
        guard key.count == 1 else { return false }
        return key != key.lowercased() || shiftedSymbol[key] != nil
    }

    private static let shiftedSymbol: [String: String] = [
        "!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5", "^": "Digit6", "&": "Digit7",
        "*": "Digit8", "(": "Digit9", ")": "Digit0", "+": "Equal", "_": "Minus", "}": "BracketRight",
        "{": "BracketLeft", "\"": "Quote", ":": "Semicolon", "|": "Backslash", "<": "Comma", "?": "Slash",
        ">": "Period", "~": "Backquote",
    ]
}
