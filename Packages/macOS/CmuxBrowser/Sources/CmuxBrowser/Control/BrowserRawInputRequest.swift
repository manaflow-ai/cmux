public import CoreGraphics
public import Foundation

/// Modifier keys of a raw input event, with the Chrome DevTools protocol's
/// bit values (`Input.dispatchMouseEvent` `modifiers`).
public struct BrowserRawInputModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let alt = BrowserRawInputModifiers(rawValue: 1)
    public static let control = BrowserRawInputModifiers(rawValue: 2)
    public static let meta = BrowserRawInputModifiers(rawValue: 4)
    public static let shift = BrowserRawInputModifiers(rawValue: 8)
}

/// One low-level input step of `browser.input_mouse` / `browser.input_keyboard`.
///
/// Steps follow the DevTools protocol's `Input.dispatchMouseEvent` and
/// `Input.dispatchKeyEvent`, so a Chromium page forwards them as they are and
/// a WebKit page replays them as native AppKit events. Points are CSS pixels
/// from the top-left of the viewport.
public enum BrowserRawInputStep: Equatable, Sendable {
    case mouseMoved(CGPoint, modifiers: BrowserRawInputModifiers)
    case mousePressed(CGPoint, button: BrowserReplMouseButton, clickCount: Int, modifiers: BrowserRawInputModifiers)
    case mouseReleased(CGPoint, button: BrowserReplMouseButton, clickCount: Int, modifiers: BrowserRawInputModifiers)
    case mouseWheel(CGPoint, deltaX: Double, deltaY: Double, modifiers: BrowserRawInputModifiers)
    /// A key goes down, by DOM `key` value (`Enter`, `a`, `ArrowLeft`).
    case keyDown(String, modifiers: BrowserRawInputModifiers)
    /// A key goes up, by DOM `key` value.
    case keyUp(String, modifiers: BrowserRawInputModifiers)
    /// Text committed as an input method would (CDP `Input.insertText`).
    case insertText(String)
}

/// Why a raw input request could not be read.
public enum BrowserRawInputRequestError: Error, Equatable, Sendable {
    /// No `args` and no `type`.
    case missingAction
    /// An action name the request family does not know.
    case unknownAction(String)
    /// A required value is absent or not a number.
    case missingValue(String)
    /// A mouse button name other than `left`, `right`, `middle` or `none`.
    case unknownButton(String)
}

/// A parsed `browser.input_mouse` or `browser.input_keyboard` request.
///
/// Two request forms are accepted:
///
/// - DevTools form: `type` plus fields, for example
///   `{"type": "mousePressed", "x": 10, "y": 20, "button": "left", "clickCount": 1}`
///   or `{"type": "keyDown", "key": "Enter"}`. Mouse types are `mouseMoved`,
///   `mousePressed`, `mouseReleased` and `mouseWheel` (`deltaX`, `deltaY`);
///   key types are `keyDown`, `rawKeyDown`, `keyUp` and `char` (`text`).
/// - Command form (`cmux browser input mouse|keyboard ...`), as `args`:
///   mouse `move X Y`, `down [BUTTON]`, `up [BUTTON]`, `click X Y [BUTTON] [COUNT]`,
///   `wheel DY [DX]`; keyboard `down KEY`, `up KEY`, `press KEY`, `type TEXT`,
///   `inserttext TEXT`.
///
/// Commands without a point (`down`, `up`, `wheel`) act where the pointer
/// last moved; pass that position as `pointer`.
public struct BrowserRawInputRequest: Equatable, Sendable {
    /// The steps to deliver, in order.
    public let steps: [BrowserRawInputStep]

    /// Reads a `browser.input_mouse` request.
    public init(mouseParams params: [String: Any], pointer: CGPoint) throws(BrowserRawInputRequestError) {
        let modifiers = Self.modifiers(params)
        if let args = Self.args(params) {
            steps = try Self.mouseSteps(args: args, pointer: pointer, modifiers: modifiers)
            return
        }
        guard let type = params["type"] as? String else { throw .missingAction }
        let point = CGPoint(
            x: Self.number(params["x"]) ?? pointer.x,
            y: Self.number(params["y"]) ?? pointer.y
        )
        let clickCount = max(1, Int(Self.number(params["clickCount"]) ?? Self.number(params["click_count"]) ?? 1))
        switch type {
        case "mouseMoved":
            steps = [.mouseMoved(point, modifiers: modifiers)]
        case "mousePressed", "mouseReleased":
            let button = try Self.button(params["button"] as? String ?? "left")
            steps = type == "mousePressed"
                ? [.mousePressed(point, button: button, clickCount: clickCount, modifiers: modifiers)]
                : [.mouseReleased(point, button: button, clickCount: clickCount, modifiers: modifiers)]
        case "mouseWheel":
            steps = [.mouseWheel(
                point,
                deltaX: Self.number(params["deltaX"]) ?? Self.number(params["delta_x"]) ?? 0,
                deltaY: Self.number(params["deltaY"]) ?? Self.number(params["delta_y"]) ?? 0,
                modifiers: modifiers
            )]
        default:
            throw .unknownAction(type)
        }
    }

    /// Reads a `browser.input_keyboard` request.
    public init(keyboardParams params: [String: Any]) throws(BrowserRawInputRequestError) {
        let modifiers = Self.modifiers(params)
        if let args = Self.args(params) {
            steps = try Self.keyboardSteps(args: args, modifiers: modifiers)
            return
        }
        guard let type = params["type"] as? String else { throw .missingAction }
        switch type {
        case "keyDown", "rawKeyDown", "keyUp":
            guard let key = params["key"] as? String, !key.isEmpty else { throw .missingValue("key") }
            steps = type == "keyUp" ? [.keyUp(key, modifiers: modifiers)] : [.keyDown(key, modifiers: modifiers)]
        case "char":
            guard let text = params["text"] as? String, !text.isEmpty else { throw .missingValue("text") }
            steps = [.insertText(text)]
        default:
            throw .unknownAction(type)
        }
    }

    // MARK: Command form

    private static func mouseSteps(
        args: [String],
        pointer: CGPoint,
        modifiers: BrowserRawInputModifiers
    ) throws(BrowserRawInputRequestError) -> [BrowserRawInputStep] {
        let verb = args[0].lowercased()
        let rest = Array(args.dropFirst())
        switch verb {
        case "move":
            return [.mouseMoved(try point(rest, at: 0), modifiers: modifiers)]
        case "down", "up":
            let button = try Self.button(rest.first ?? "left")
            return verb == "down"
                ? [.mousePressed(pointer, button: button, clickCount: 1, modifiers: modifiers)]
                : [.mouseReleased(pointer, button: button, clickCount: 1, modifiers: modifiers)]
        case "click":
            let at = try point(rest, at: 0)
            let button = try Self.button(rest.count > 2 ? rest[2] : "left")
            let count = rest.count > 3 ? max(1, Int(number(rest[3]) ?? 1)) : 1
            var steps: [BrowserRawInputStep] = [.mouseMoved(at, modifiers: modifiers)]
            for click in 1...count {
                steps.append(.mousePressed(at, button: button, clickCount: click, modifiers: modifiers))
                steps.append(.mouseReleased(at, button: button, clickCount: click, modifiers: modifiers))
            }
            return steps
        case "wheel", "scroll":
            guard let deltaY = rest.first.flatMap({ number($0) }) else { throw .missingValue("deltaY") }
            let deltaX = rest.count > 1 ? (number(rest[1]) ?? 0) : 0
            return [.mouseWheel(pointer, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)]
        default:
            throw .unknownAction(args[0])
        }
    }

    private static func keyboardSteps(
        args: [String],
        modifiers: BrowserRawInputModifiers
    ) throws(BrowserRawInputRequestError) -> [BrowserRawInputStep] {
        let verb = args[0].lowercased()
        let rest = Array(args.dropFirst())
        switch verb {
        case "down", "keydown", "up", "keyup", "press":
            guard let key = rest.first, !key.isEmpty else { throw .missingValue("key") }
            switch verb {
            case "down", "keydown": return [.keyDown(key, modifiers: modifiers)]
            case "up", "keyup": return [.keyUp(key, modifiers: modifiers)]
            default: return [.keyDown(key, modifiers: modifiers), .keyUp(key, modifiers: modifiers)]
            }
        case "type":
            let text = rest.joined(separator: " ")
            guard !text.isEmpty else { throw .missingValue("text") }
            return text.flatMap { character -> [BrowserRawInputStep] in
                let key = String(character)
                return [.keyDown(key, modifiers: modifiers), .keyUp(key, modifiers: modifiers)]
            }
        case "inserttext", "insert":
            let text = rest.joined(separator: " ")
            guard !text.isEmpty else { throw .missingValue("text") }
            return [.insertText(text)]
        default:
            throw .unknownAction(args[0])
        }
    }

    // MARK: Values

    private static func args(_ params: [String: Any]) -> [String]? {
        guard let raw = params["args"] as? [Any] else { return nil }
        let args = raw.map { ($0 as? String) ?? String(describing: $0) }
        return args.isEmpty ? nil : args
    }

    private static func point(_ values: [String], at index: Int) throws(BrowserRawInputRequestError) -> CGPoint {
        guard values.count > index + 1,
              let x = number(values[index]),
              let y = number(values[index + 1]) else {
            throw .missingValue("x y")
        }
        return CGPoint(x: x, y: y)
    }

    private static func button(_ name: String) throws(BrowserRawInputRequestError) -> BrowserReplMouseButton {
        switch name.lowercased() {
        case "left", "none": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw .unknownButton(name)
        }
    }

    private static func modifiers(_ params: [String: Any]) -> BrowserRawInputModifiers {
        BrowserRawInputModifiers(rawValue: Int(number(params["modifiers"]) ?? 0) & 0xF)
    }

    private static func number(_ value: Any?) -> Double? {
        let double: Double?
        switch value {
        case let number as NSNumber: double = number.doubleValue
        case let text as String: double = Double(text.trimmingCharacters(in: .whitespaces))
        default: double = nil
        }
        guard let double, double.isFinite else { return nil }
        return double
    }
}
