import AppKit

/// Converts native key events to Chrome DevTools Protocol key fields.
struct ChromiumKeyMapping {
    struct Value: Sendable {
        let key: String
        let code: String
        let text: String?
        let modifiers: Int
    }

    static func map(_ event: NSEvent) -> Value {
        let key = keyName(for: event)
        let code = codeName(for: event)
        // CDP text must preserve the native event's Shift/Option transform.
        // charactersIgnoringModifiers is still appropriate for the physical
        // key fallback below, but would type the wrong glyph into the page.
        let flags = event.modifierFlags
        let text = flags.contains(.command) || flags.contains(.control)
            ? nil : event.characters.flatMap { $0.isEmpty ? nil : $0 }
        return Value(key: key, code: code, text: text, modifiers: modifiers(flags))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        // CDP defines only these four bits; Caps Lock is represented by the
        // resulting text, not an invented fifth modifier bit.
        (flags.contains(.option) ? 1 : 0)
            | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.command) ? 4 : 0)
            | (flags.contains(.shift) ? 8 : 0)
    }

    private static func keyName(for event: NSEvent) -> String {
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

    private static func codeName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 117: return "Delete"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return physicalCodes[event.keyCode] ?? "Unidentified"
        }
    }

    // macOS virtual key codes identify physical positions independently of
    // keyboard layout, Shift, and Option. DOM `code` uses that same identity.
    private static let physicalCodes: [UInt16: String] = [
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG",
        6: "KeyZ", 7: "KeyX", 8: "KeyC", 9: "KeyV", 11: "KeyB", 12: "KeyQ",
        13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT",
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6",
        23: "Digit5", 24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus",
        28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO", 32: "KeyU",
        33: "BracketLeft", 34: "KeyI", 35: "KeyP", 37: "KeyL", 38: "KeyJ",
        39: "Quote", 40: "KeyK", 41: "Semicolon", 42: "Backslash", 43: "Comma",
        44: "Slash", 45: "KeyN", 46: "KeyM", 47: "Period", 50: "Backquote",
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
    ]
}
