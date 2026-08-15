import AppKit

/// Converts native key events to Chrome DevTools Protocol key fields.
enum ChromiumKeyMapping {
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
        let text = event.characters.flatMap { $0.isEmpty ? nil : $0 }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.option) { modifiers |= altBit }
        if flags.contains(.control) { modifiers |= controlBit }
        if flags.contains(.command) { modifiers |= commandBit }
        if flags.contains(.shift) { modifiers |= shiftBit }
        if flags.contains(.capsLock) { modifiers |= capsLockBit }
        return Value(key: key, code: code, text: text, modifiers: modifiers)
    }

    private static let altBit = 1
    private static let controlBit = 2
    private static let commandBit = 4
    private static let shiftBit = 8
    private static let capsLockBit = 16

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
        default: return event.charactersIgnoringModifiers ?? "Unidentified"
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
        default:
            return event.charactersIgnoringModifiers.map {
                "Key" + $0.uppercased()
            } ?? "Unidentified"
        }
    }
}
