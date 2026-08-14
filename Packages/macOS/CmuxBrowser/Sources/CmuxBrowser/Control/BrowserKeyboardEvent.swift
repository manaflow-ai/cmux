/// The canonical DOM keyboard-event fields for a browser automation key name.
///
/// Named keys follow Playwright's US keyboard layout and the W3C UI Events
/// key/code registries. Unknown non-empty values pass through unchanged so
/// existing callers can still send DOM key values that are not in the registry.
public struct BrowserKeyboardEvent: Equatable, Sendable {
    /// The value exposed as `KeyboardEvent.key`.
    public let key: String

    /// The value exposed as `KeyboardEvent.code`.
    public let code: String

    /// The legacy value exposed as `KeyboardEvent.keyCode` and `which`.
    public let legacyKeyCode: Int

    /// The value exposed as `KeyboardEvent.location`.
    public let location: Int

    /// Resolves an RPC key parameter into canonical DOM keyboard-event fields.
    ///
    /// The raw value is intentionally not trimmed: a single space is the DOM
    /// `key` value for the Space key. Missing and genuinely empty values remain
    /// invalid.
    ///
    /// - Parameter rawKey: The unmodified string from the RPC request.
    public init?(rawKey: String?) {
        guard let rawKey, !rawKey.isEmpty else { return nil }

        if let named = Self.namedKeys[rawKey] {
            self = named
        } else if rawKey.utf16.count == 1, let codeUnit = rawKey.utf16.first {
            self.init(key: rawKey, code: "", legacyKeyCode: Int(codeUnit))
        } else {
            self.init(key: rawKey, code: rawKey, legacyKeyCode: 0)
        }
    }

    private init(key: String, code: String, legacyKeyCode: Int, location: Int = 0) {
        self.key = key
        self.code = code
        self.legacyKeyCode = legacyKeyCode
        self.location = location
    }

    private static let namedKeys: [String: BrowserKeyboardEvent] = {
        var keys: [String: BrowserKeyboardEvent] = [
            "Escape": .init(key: "Escape", code: "Escape", legacyKeyCode: 27),
            "Esc": .init(key: "Escape", code: "Escape", legacyKeyCode: 27),

            "Backquote": .init(key: "`", code: "Backquote", legacyKeyCode: 192),
            "`": .init(key: "`", code: "Backquote", legacyKeyCode: 192),
            "~": .init(key: "~", code: "Backquote", legacyKeyCode: 192),
            "Digit1": .init(key: "1", code: "Digit1", legacyKeyCode: 49),
            "1": .init(key: "1", code: "Digit1", legacyKeyCode: 49),
            "!": .init(key: "!", code: "Digit1", legacyKeyCode: 49),
            "Digit2": .init(key: "2", code: "Digit2", legacyKeyCode: 50),
            "2": .init(key: "2", code: "Digit2", legacyKeyCode: 50),
            "@": .init(key: "@", code: "Digit2", legacyKeyCode: 50),
            "Digit3": .init(key: "3", code: "Digit3", legacyKeyCode: 51),
            "3": .init(key: "3", code: "Digit3", legacyKeyCode: 51),
            "#": .init(key: "#", code: "Digit3", legacyKeyCode: 51),
            "Digit4": .init(key: "4", code: "Digit4", legacyKeyCode: 52),
            "4": .init(key: "4", code: "Digit4", legacyKeyCode: 52),
            "$": .init(key: "$", code: "Digit4", legacyKeyCode: 52),
            "Digit5": .init(key: "5", code: "Digit5", legacyKeyCode: 53),
            "5": .init(key: "5", code: "Digit5", legacyKeyCode: 53),
            "%": .init(key: "%", code: "Digit5", legacyKeyCode: 53),
            "Digit6": .init(key: "6", code: "Digit6", legacyKeyCode: 54),
            "6": .init(key: "6", code: "Digit6", legacyKeyCode: 54),
            "^": .init(key: "^", code: "Digit6", legacyKeyCode: 54),
            "Digit7": .init(key: "7", code: "Digit7", legacyKeyCode: 55),
            "7": .init(key: "7", code: "Digit7", legacyKeyCode: 55),
            "&": .init(key: "&", code: "Digit7", legacyKeyCode: 55),
            "Digit8": .init(key: "8", code: "Digit8", legacyKeyCode: 56),
            "8": .init(key: "8", code: "Digit8", legacyKeyCode: 56),
            "*": .init(key: "*", code: "Digit8", legacyKeyCode: 56),
            "Digit9": .init(key: "9", code: "Digit9", legacyKeyCode: 57),
            "9": .init(key: "9", code: "Digit9", legacyKeyCode: 57),
            "(": .init(key: "(", code: "Digit9", legacyKeyCode: 57),
            "Digit0": .init(key: "0", code: "Digit0", legacyKeyCode: 48),
            "0": .init(key: "0", code: "Digit0", legacyKeyCode: 48),
            ")": .init(key: ")", code: "Digit0", legacyKeyCode: 48),
            "Minus": .init(key: "-", code: "Minus", legacyKeyCode: 189),
            "-": .init(key: "-", code: "Minus", legacyKeyCode: 189),
            "_": .init(key: "_", code: "Minus", legacyKeyCode: 189),
            "Equal": .init(key: "=", code: "Equal", legacyKeyCode: 187),
            "=": .init(key: "=", code: "Equal", legacyKeyCode: 187),
            "+": .init(key: "+", code: "Equal", legacyKeyCode: 187),
            "Backslash": .init(key: "\\", code: "Backslash", legacyKeyCode: 220),
            "\\": .init(key: "\\", code: "Backslash", legacyKeyCode: 220),
            "|": .init(key: "|", code: "Backslash", legacyKeyCode: 220),
            "Backspace": .init(key: "Backspace", code: "Backspace", legacyKeyCode: 8),

            "Tab": .init(key: "Tab", code: "Tab", legacyKeyCode: 9),
            "\t": .init(key: "Tab", code: "Tab", legacyKeyCode: 9),
            "BracketLeft": .init(key: "[", code: "BracketLeft", legacyKeyCode: 219),
            "[": .init(key: "[", code: "BracketLeft", legacyKeyCode: 219),
            "{": .init(key: "{", code: "BracketLeft", legacyKeyCode: 219),
            "BracketRight": .init(key: "]", code: "BracketRight", legacyKeyCode: 221),
            "]": .init(key: "]", code: "BracketRight", legacyKeyCode: 221),
            "}": .init(key: "}", code: "BracketRight", legacyKeyCode: 221),

            "CapsLock": .init(key: "CapsLock", code: "CapsLock", legacyKeyCode: 20),
            "Semicolon": .init(key: ";", code: "Semicolon", legacyKeyCode: 186),
            ";": .init(key: ";", code: "Semicolon", legacyKeyCode: 186),
            ":": .init(key: ":", code: "Semicolon", legacyKeyCode: 186),
            "Quote": .init(key: "'", code: "Quote", legacyKeyCode: 222),
            "'": .init(key: "'", code: "Quote", legacyKeyCode: 222),
            "\"": .init(key: "\"", code: "Quote", legacyKeyCode: 222),
            "Enter": .init(key: "Enter", code: "Enter", legacyKeyCode: 13),
            "Return": .init(key: "Enter", code: "Enter", legacyKeyCode: 13),
            "\n": .init(key: "Enter", code: "Enter", legacyKeyCode: 13),
            "\r": .init(key: "Enter", code: "Enter", legacyKeyCode: 13),

            "Shift": .init(key: "Shift", code: "ShiftLeft", legacyKeyCode: 16, location: 1),
            "ShiftLeft": .init(key: "Shift", code: "ShiftLeft", legacyKeyCode: 16, location: 1),
            "ShiftRight": .init(key: "Shift", code: "ShiftRight", legacyKeyCode: 16, location: 2),
            "Comma": .init(key: ",", code: "Comma", legacyKeyCode: 188),
            ",": .init(key: ",", code: "Comma", legacyKeyCode: 188),
            "<": .init(key: "<", code: "Comma", legacyKeyCode: 188),
            "Period": .init(key: ".", code: "Period", legacyKeyCode: 190),
            ".": .init(key: ".", code: "Period", legacyKeyCode: 190),
            ">": .init(key: ">", code: "Period", legacyKeyCode: 190),
            "Slash": .init(key: "/", code: "Slash", legacyKeyCode: 191),
            "/": .init(key: "/", code: "Slash", legacyKeyCode: 191),
            "?": .init(key: "?", code: "Slash", legacyKeyCode: 191),

            "Control": .init(key: "Control", code: "ControlLeft", legacyKeyCode: 17, location: 1),
            "ControlLeft": .init(key: "Control", code: "ControlLeft", legacyKeyCode: 17, location: 1),
            "ControlRight": .init(key: "Control", code: "ControlRight", legacyKeyCode: 17, location: 2),
            "Meta": .init(key: "Meta", code: "MetaLeft", legacyKeyCode: 91, location: 1),
            "ControlOrMeta": .init(key: "Meta", code: "MetaLeft", legacyKeyCode: 91, location: 1),
            "MetaLeft": .init(key: "Meta", code: "MetaLeft", legacyKeyCode: 91, location: 1),
            "MetaRight": .init(key: "Meta", code: "MetaRight", legacyKeyCode: 92, location: 2),
            "Alt": .init(key: "Alt", code: "AltLeft", legacyKeyCode: 18, location: 1),
            "AltLeft": .init(key: "Alt", code: "AltLeft", legacyKeyCode: 18, location: 1),
            "AltRight": .init(key: "Alt", code: "AltRight", legacyKeyCode: 18, location: 2),
            "Space": .init(key: " ", code: "Space", legacyKeyCode: 32),
            "Spacebar": .init(key: " ", code: "Space", legacyKeyCode: 32),
            "space": .init(key: " ", code: "Space", legacyKeyCode: 32),
            " ": .init(key: " ", code: "Space", legacyKeyCode: 32),
            "AltGraph": .init(key: "AltGraph", code: "AltGraph", legacyKeyCode: 225),
            "ContextMenu": .init(key: "ContextMenu", code: "ContextMenu", legacyKeyCode: 93),

            "PrintScreen": .init(key: "PrintScreen", code: "PrintScreen", legacyKeyCode: 44),
            "ScrollLock": .init(key: "ScrollLock", code: "ScrollLock", legacyKeyCode: 145),
            "Pause": .init(key: "Pause", code: "Pause", legacyKeyCode: 19),
            "PageUp": .init(key: "PageUp", code: "PageUp", legacyKeyCode: 33),
            "PageDown": .init(key: "PageDown", code: "PageDown", legacyKeyCode: 34),
            "Insert": .init(key: "Insert", code: "Insert", legacyKeyCode: 45),
            "Delete": .init(key: "Delete", code: "Delete", legacyKeyCode: 46),
            "Del": .init(key: "Delete", code: "Delete", legacyKeyCode: 46),
            "Home": .init(key: "Home", code: "Home", legacyKeyCode: 36),
            "End": .init(key: "End", code: "End", legacyKeyCode: 35),
            "ArrowLeft": .init(key: "ArrowLeft", code: "ArrowLeft", legacyKeyCode: 37),
            "ArrowUp": .init(key: "ArrowUp", code: "ArrowUp", legacyKeyCode: 38),
            "ArrowRight": .init(key: "ArrowRight", code: "ArrowRight", legacyKeyCode: 39),
            "ArrowDown": .init(key: "ArrowDown", code: "ArrowDown", legacyKeyCode: 40),

            "AudioVolumeMute": .init(key: "AudioVolumeMute", code: "AudioVolumeMute", legacyKeyCode: 173),
            "AudioVolumeDown": .init(key: "AudioVolumeDown", code: "AudioVolumeDown", legacyKeyCode: 174),
            "AudioVolumeUp": .init(key: "AudioVolumeUp", code: "AudioVolumeUp", legacyKeyCode: 175),
            "MediaTrackNext": .init(key: "MediaTrackNext", code: "MediaTrackNext", legacyKeyCode: 176),
            "MediaTrackPrevious": .init(key: "MediaTrackPrevious", code: "MediaTrackPrevious", legacyKeyCode: 177),
            "MediaPlayPause": .init(key: "MediaPlayPause", code: "MediaPlayPause", legacyKeyCode: 179),

            "NumLock": .init(key: "NumLock", code: "NumLock", legacyKeyCode: 144),
            "NumpadDivide": .init(key: "/", code: "NumpadDivide", legacyKeyCode: 111, location: 3),
            "NumpadMultiply": .init(key: "*", code: "NumpadMultiply", legacyKeyCode: 106, location: 3),
            "NumpadSubtract": .init(key: "-", code: "NumpadSubtract", legacyKeyCode: 109, location: 3),
            "Numpad7": .init(key: "Home", code: "Numpad7", legacyKeyCode: 36, location: 3),
            "Numpad8": .init(key: "ArrowUp", code: "Numpad8", legacyKeyCode: 38, location: 3),
            "Numpad9": .init(key: "PageUp", code: "Numpad9", legacyKeyCode: 33, location: 3),
            "Numpad4": .init(key: "ArrowLeft", code: "Numpad4", legacyKeyCode: 37, location: 3),
            "Numpad5": .init(key: "Clear", code: "Numpad5", legacyKeyCode: 12, location: 3),
            "Numpad6": .init(key: "ArrowRight", code: "Numpad6", legacyKeyCode: 39, location: 3),
            "NumpadAdd": .init(key: "+", code: "NumpadAdd", legacyKeyCode: 107, location: 3),
            "Numpad1": .init(key: "End", code: "Numpad1", legacyKeyCode: 35, location: 3),
            "Numpad2": .init(key: "ArrowDown", code: "Numpad2", legacyKeyCode: 40, location: 3),
            "Numpad3": .init(key: "PageDown", code: "Numpad3", legacyKeyCode: 34, location: 3),
            "Numpad0": .init(key: "Insert", code: "Numpad0", legacyKeyCode: 45, location: 3),
            "NumpadDecimal": .init(key: "\0", code: "NumpadDecimal", legacyKeyCode: 46, location: 3),
            "NumpadEnter": .init(key: "Enter", code: "NumpadEnter", legacyKeyCode: 13, location: 3),
        ]

        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            guard let unicodeScalar = UnicodeScalar(scalar) else { continue }
            let uppercase = String(unicodeScalar)
            let lowercase = uppercase.lowercased()
            let event = BrowserKeyboardEvent(
                key: lowercase,
                code: "Key\(uppercase)",
                legacyKeyCode: Int(scalar)
            )
            keys["Key\(uppercase)"] = event
            keys[lowercase] = event
            keys[uppercase] = .init(
                key: uppercase,
                code: "Key\(uppercase)",
                legacyKeyCode: Int(scalar)
            )
        }

        for number in 1...12 {
            let name = "F\(number)"
            keys[name] = .init(key: name, code: name, legacyKeyCode: 111 + number)
        }

        return keys
    }()
}
