import CmuxNextSettings
import Foundation

/// `browser.page.press|hover|scroll|scroll_into_view|select|check|uncheck`:
/// the old `cmux browser` input verbs, as page scripts like `click` and
/// `fill`. A script's `{error, code}` becomes that error code (`not_found`,
/// `not_checkable`, `disabled`, `not_changed`, `not_select`).
extension BrowserPageService {
    func inputMethods() -> [ControlMethod] {
        let engine = engine
        return [
            input("press", engine: engine) { call in
                // Unknown names pass through as an opaque key, as the old app did.
                let key = BrowserPageKey(try Self.string(call, "key"))
                return BrowserPageScripts.press(key, selector: Self.optionalString(call, "selector"))
            },
            input("hover", engine: engine) { BrowserPageScripts.hover(try Self.string($0, "selector")) },
            input("scroll_into_view", engine: engine) { BrowserPageScripts.scrollIntoView(try Self.string($0, "selector")) },
            input("scroll", engine: engine) { call in
                let params = call.request.params
                let dx = try Self.offset(call, "dx"), dy = try Self.offset(call, "dy")
                guard params["dx"] != nil || params["dy"] != nil else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.scrollOffset", "browser.page.scroll needs params.dx or params.dy"))
                }
                return BrowserPageScripts.scroll(Self.optionalString(call, "selector"), dx: dx, dy: dy)
            },
            input("select", engine: engine) { call in
                // An empty value is an option too, so this is not Self.string.
                guard let value = call.request.params["value"]?.stringValue else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                           call.request.method, "value"))
                }
                return BrowserPageScripts.select(try Self.string(call, "selector"), value: value)
            },
            input("check", engine: engine) { BrowserPageScripts.check(try Self.string($0, "selector"), true) },
            input("uncheck", engine: engine) { BrowserPageScripts.check(try Self.string($0, "selector"), false) },
        ]
    }

    private func input(_ name: String, engine: any BrowserPageEngine,
                       _ make: @escaping @Sendable (ControlCall) throws -> String) -> ControlMethod {
        .async("browser.page.\(name)") { call in
            let script = try make(call)
            let tab = try Self.tab(call)
            let value = try await Self.run(engine, .evaluate(script), tab)["value"] ?? .null
            if let error = value["error"]?.stringValue {
                var data: [String: JSONValue] = [:]
                if let selector = call.request.params["selector"] { data["selector"] = selector }
                throw ControlError(code: value["code"]?.stringValue ?? "not_found", message: error, data: .object(data))
            }
            var result = Self.base(tab)
            result["value"] = value["value"] ?? .null
            return .object(result)
        }
    }

    static func optionalString(_ call: ControlCall, _ key: String) -> String? {
        call.request.params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A finite number of CSS pixels, 0 when absent.
    static func offset(_ call: ControlCall, _ key: String) throws -> Double {
        guard let raw = call.request.params[key] else { return 0 }
        guard let value = raw.doubleValue, value.isFinite else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.scrollOffsetNumber", "params.%@ must be a finite number of pixels", key))
        }
        return value
    }
}
