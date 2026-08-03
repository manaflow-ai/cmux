import AppKit

/// Immutable keyboard translation data read by synchronous event handlers.
/// Carbon input-source APIs are used only while constructing a replacement.
struct KeyboardLayoutSnapshot: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let keyCode: UInt16
        private let modifierFlagsRawValue: UInt

        init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifierFlagsRawValue = modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .rawValue
        }
    }

    let inputSourceID: String?
    private let shortcutCharacters: [Key: String]
    private let textInputCharacters: [Key: String]

    init(
        inputSourceID: String?,
        shortcutCharacters: [Key: String],
        textInputCharacters: [Key: String]
    ) {
        self.inputSourceID = inputSourceID
        self.shortcutCharacters = shortcutCharacters
        self.textInputCharacters = textInputCharacters
    }

    func shortcutCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .command])
        return shortcutCharacters[Key(keyCode: keyCode, modifierFlags: normalized)]
    }

    func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .option])
        return textInputCharacters[Key(keyCode: keyCode, modifierFlags: normalized)]
    }

    func replacingInputSourceID(_ inputSourceID: String?) -> Self {
        Self(
            inputSourceID: inputSourceID,
            shortcutCharacters: shortcutCharacters,
            textInputCharacters: textInputCharacters
        )
    }

    static let usBootstrap: Self = {
        let baseCharacters: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y",
            17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
            31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "\r", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: ".", 48: "\t", 49: " ", 50: "`",
        ]
        let shiftedCharacters: [UInt16: String] = [
            18: "!", 19: "@", 20: "#", 21: "$", 22: "^", 23: "%", 24: "+",
            25: "(", 26: "&", 27: "_", 28: "*", 29: ")", 30: "}", 33: "{",
            39: "\"", 41: ":", 42: "|", 43: "<", 44: "?", 47: ">", 50: "~",
        ]
        var shortcutCharacters: [Key: String] = [:]
        for (keyCode, baseCharacter) in baseCharacters {
            let shiftedCharacter = shiftedCharacters[keyCode] ?? baseCharacter
            shortcutCharacters[Key(keyCode: keyCode, modifierFlags: [])] = baseCharacter
            shortcutCharacters[Key(keyCode: keyCode, modifierFlags: .command)] = baseCharacter
            shortcutCharacters[Key(keyCode: keyCode, modifierFlags: .shift)] = shiftedCharacter
            shortcutCharacters[Key(keyCode: keyCode, modifierFlags: [.shift, .command])] = shiftedCharacter
        }
        return Self(
            inputSourceID: "com.apple.keylayout.US",
            shortcutCharacters: shortcutCharacters,
            textInputCharacters: [:]
        )
    }()
}
