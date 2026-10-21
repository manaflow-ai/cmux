import CmuxNextSettings
import Foundation

/// `browser.page.mouse|wheel|insert_text|key`: raw input on an app browser tab (WebKit or CEF),
/// at a viewport point in CSS px or on the focused element. Daemon `browser.input.mouse|wheel|
/// text|key` on a page the app draws runs these (the CLI and MCP route them,
/// `cli/app_browser_route.rs`).
///
/// - `mouse {kind: down|up|move|click, x, y, button?: left|middle|right|back|forward,
///   click_count?: 1…100, modifiers?}`; `button` is left by default.
/// - `wheel {x, y, dx?, dy?, modifiers?}`: at least one of `dx`, `dy`.
/// - `insert_text {text}`: into the focused text field or editable element; `not_editable`
///   when nothing editable has focus.
/// - `key {key, kind?: down|up|press, modifiers?}`: key names as `browser.page.press` reads them.
///
/// `modifiers` holds `shift`, `control`, `alt` and `meta`.
extension BrowserPageService {
    static let mouseKinds = ["down", "up", "move", "click"]
    static let mouseButtons = ["left", "middle", "right", "back", "forward"]
    static let keyKinds = ["down", "up", "press"]
    static let modifierNames: Set<String> = ["shift", "control", "alt", "meta"]

    func rawInputMethods() -> [ControlMethod] {
        let engine = engine
        return [
            raw("mouse", engine: engine, announce: { call, answer in
                .from(kind: call.request.params["kind"]?.stringValue == "move" ? .hover : .click, answer: answer)
            }) { call in
                let kind = try Self.choice(call, "kind", Self.mouseKinds, default: nil)
                let button = try Self.choice(call, "button", Self.mouseButtons, default: "left")
                return BrowserPageScripts.mouse(kind: kind, x: try Self.point(call, "x"), y: try Self.point(call, "y"),
                                                button: button, clickCount: try Self.clickCount(call),
                                                modifiers: try Self.modifiers(call))
            },
            raw("wheel", engine: engine, announce: { _, answer in .from(kind: .scroll, answer: answer) }) { call in
                let params = call.request.params
                guard params["dx"] != nil || params["dy"] != nil else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.wheelOffset", "browser.page.wheel needs params.dx or params.dy"))
                }
                return BrowserPageScripts.wheel(x: try Self.point(call, "x"), y: try Self.point(call, "y"),
                                                dx: try Self.offset(call, "dx"), dy: try Self.offset(call, "dy"),
                                                modifiers: try Self.modifiers(call))
            },
            raw("insert_text", engine: engine, announce: { call, answer in
                .from(kind: .type, answer: answer, text: call.request.params["text"]?.stringValue)
            }) { call in
                BrowserPageScripts.insertText(try Self.string(call, "text"))
            },
            raw("key", engine: engine, announce: { call, answer in
                .from(kind: .key, answer: answer, key: call.request.params["key"]?.stringValue)
            }) { call in
                let kind = try Self.choice(call, "kind", Self.keyKinds, default: "press")
                return BrowserPageScripts.key(BrowserPressKey(try Self.string(call, "key")), kind: kind,
                                              modifiers: try Self.modifiers(call))
            },
        ]
    }

    /// `announce` turns a successful answer into the agent input the agent cursor draws.
    private func raw(_ name: String, engine: any BrowserPageEngine,
                     announce: @escaping @Sendable (ControlCall, JSONValue) -> BrowserPageAgentInput?,
                     _ make: @escaping @Sendable (ControlCall) throws -> String) -> ControlMethod {
        .async("browser.page.\(name)") { call in
            let script = try make(call)
            let tab = try Self.tab(call)
            let value = try await Self.run(engine, .evaluate(script), tab)["value"] ?? .null
            if let error = value["error"]?.stringValue {
                let code = value["code"]?.stringValue ?? "not_found"
                let message = code == "not_editable"
                    ? ControlStrings.text("control.error.notEditable", "The focused element takes no text; focus a text field first")
                    : error
                throw ControlError(code: code, message: message)
            }
            if let input = announce(call, value) {
                await engine.announce(Self.attributed(input, call), tabID: tab.id)
            }
            var result = Self.base(tab)
            result["value"] = value["value"] ?? .null
            return .object(result)
        }
    }

    /// `params[key]`, one of `allowed`; `fallback` when absent (nil: required).
    static func choice(_ call: ControlCall, _ key: String, _ allowed: [String], default fallback: String?) throws -> String {
        let raw = call.request.params[key, default: .null]
        guard raw != .null else {
            if let fallback { return fallback }
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                   call.request.method, key))
        }
        guard let value = raw.stringValue, allowed.contains(value) else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.rawInputChoice", "params.%1$@ must be one of %2$@",
                                                                   key, allowed.joined(separator: ", ")))
        }
        return value
    }

    /// A required finite coordinate in viewport CSS px.
    static func point(_ call: ControlCall, _ key: String) throws -> Double {
        guard call.request.params[key, default: .null] != .null else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                   call.request.method, key))
        }
        return try offset(call, key)
    }

    /// `params.click_count`, 1 when absent.
    static func clickCount(_ call: ControlCall) throws -> Int {
        guard let raw = call.request.params["click_count"], raw != .null else { return 1 }
        guard let value = raw.doubleValue, let count = Int(exactly: value), (1...100).contains(count) else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.rawInputClickCount", "params.click_count must be a whole number from 1 to 100"))
        }
        return count
    }

    /// `params.modifiers`: a list of `shift`, `control`, `alt`, `meta`; empty when absent.
    static func modifiers(_ call: ControlCall) throws -> Set<String> {
        guard let raw = call.request.params["modifiers"], raw != .null else { return [] }
        guard let list = raw.arrayValue?.map(\.stringValue), list.allSatisfy({ name in name.map { modifierNames.contains($0) } ?? false }) else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.rawInputModifiers", "params.modifiers may hold only shift, control, alt and meta"))
        }
        return Set(list.compactMap { $0 })
    }
}
