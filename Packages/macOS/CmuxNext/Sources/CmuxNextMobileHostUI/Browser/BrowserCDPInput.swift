public import CmuxBrowserStream

/// One DevTools `Input.*` command.
public struct CDPCall: Hashable, Sendable {
    public var method: String
    public var params: [String: CDPValue]

    public init(method: String, params: [String: CDPValue]) {
        self.method = method
        self.params = params
    }

    /// The params as the engine's DevTools API takes them.
    public var foundationParams: [String: any Sendable] {
        params.mapValues(\.foundation)
    }
}

/// A DevTools parameter value.
public enum CDPValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case strings([String])

    var foundation: any Sendable {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .strings(let value): return value
        }
    }
}

/// rb input in page CSS pixels to DevTools `Input` commands
/// (`dispatchMouseEvent`, `dispatchKeyEvent`, `insertText`,
/// `imeSetComposition`): trusted events, like the person's own. Pure.
public enum BrowserCDPInput {
    public static func calls(for input: RbInputEvent) -> [CDPCall] {
        switch input {
        case .pointer(let kind, let x, let y, let button, let buttons, let clickCount, let modifiers, let pointerType):
            let type: String = switch kind {
            case .down: "mousePressed"
            case .up: "mouseReleased"
            case .move, .enter, .leave: "mouseMoved"
            }
            let pressed = kind == .down || kind == .up
            return [CDPCall(method: "Input.dispatchMouseEvent", params: [
                "type": .string(type), "x": .double(x), "y": .double(y),
                "button": .string(pressed ? buttonName(button) : (buttons == 0 ? "none" : buttonName(firstButton(buttons)))),
                "buttons": .int(Int(buttons)), "clickCount": .int(pressed ? max(1, Int(clickCount)) : 0),
                "modifiers": .int(cdpModifiers(modifiers)), "pointerType": .string(pointerType == "pen" ? "pen" : "mouse"),
            ])]
        case .wheel(let x, let y, let dx, let dy, _, _, _, let modifiers):
            return [CDPCall(method: "Input.dispatchMouseEvent", params: [
                "type": .string("mouseWheel"), "x": .double(x), "y": .double(y), "deltaX": .double(dx), "deltaY": .double(dy),
                "modifiers": .int(cdpModifiers(modifiers)),
            ])]
        case .key(let key):
            var params: [String: CDPValue] = [
                "type": .string(key.down ? (key.text.isEmpty ? "rawKeyDown" : "keyDown") : "keyUp"),
                "key": .string(key.key), "code": .string(key.code), "modifiers": .int(cdpModifiers(key.modifiers)),
                "autoRepeat": .bool(key.isRepeat), "location": .int(Int(key.location)),
            ]
            if key.down, !key.text.isEmpty {
                params["text"] = .string(key.text)
                params["unmodifiedText"] = .string(key.unmodifiedText.isEmpty ? key.text : key.unmodifiedText)
            }
            if let code = virtualKeyCode(key.code) { params["windowsVirtualKeyCode"] = .int(code) }
            if key.down, !key.editCommands.isEmpty { params["commands"] = .strings(key.editCommands.map(\.name)) }
            return [CDPCall(method: "Input.dispatchKeyEvent", params: params)]
        case .imeCommit(let text, _):
            return [CDPCall(method: "Input.insertText", params: ["text": .string(text)])]
        case .imeSetComposition(let text, _, let start, let end, _):
            return [CDPCall(method: "Input.imeSetComposition", params: [
                "text": .string(text), "selectionStart": .int(Int(start)), "selectionEnd": .int(Int(end)),
            ])]
        case .imeCancel:
            return [CDPCall(method: "Input.imeSetComposition", params: [
                "text": .string(""), "selectionStart": .int(0), "selectionEnd": .int(0),
            ])]
        case .imeFinish, .pinch:
            // A finished composition was already committed; page zoom stays the Mac's.
            return []
        }
    }

    /// DOM button numbers (0 main, 1 auxiliary, 2 secondary) to DevTools names.
    static func buttonName(_ button: UInt8) -> String {
        switch button {
        case 1: "middle"
        case 2: "right"
        case 3: "back"
        case 4: "forward"
        default: "left"
        }
    }

    /// The first pressed button of a DOM `buttons` mask (1 main, 2 secondary, 4 auxiliary).
    static func firstButton(_ buttons: UInt8) -> UInt8 {
        if buttons & 1 != 0 { return 0 }
        if buttons & 2 != 0 { return 2 }
        if buttons & 4 != 0 { return 1 }
        return 0
    }

    /// DevTools modifiers: Alt 1, Ctrl 2, Meta 4, Shift 8.
    static func cdpModifiers(_ modifiers: RbModifiers) -> Int {
        var value = 0
        if modifiers.contains(.option) { value |= 1 }
        if modifiers.contains(.control) { value |= 2 }
        if modifiers.contains(.command) { value |= 4 }
        if modifiers.contains(.shift) { value |= 8 }
        return value
    }

    /// Windows virtual key codes Chromium needs for keys without text.
    static func virtualKeyCode(_ code: String) -> Int? {
        switch code {
        case "Backspace": return 8
        case "Tab": return 9
        case "Enter", "NumpadEnter": return 13
        case "Escape": return 27
        case "Space": return 32
        case "PageUp": return 33
        case "PageDown": return 34
        case "End": return 35
        case "Home": return 36
        case "ArrowLeft": return 37
        case "ArrowUp": return 38
        case "ArrowRight": return 39
        case "ArrowDown": return 40
        case "Delete": return 46
        default:
            if code.hasPrefix("Key"), code.count == 4, let letter = code.last?.asciiValue, (65...90).contains(letter) {
                return Int(letter)
            }
            if code.hasPrefix("Digit"), code.count == 6, let digit = code.last?.asciiValue, (48...57).contains(digit) {
                return Int(digit)
            }
            return nil
        }
    }
}
