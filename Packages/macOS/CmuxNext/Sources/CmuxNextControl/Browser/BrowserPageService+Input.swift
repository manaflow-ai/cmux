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
            input("press", engine: engine, announce: { call, answer in
                .from(kind: .key, answer: answer, key: call.request.params["key"]?.stringValue)
            }) { call in
                // Unknown names pass through as an opaque key, as the old app did.
                let key = BrowserPressKey(try Self.string(call, "key"))
                return BrowserPageScripts.press(key, selector: Self.optionalString(call, "selector"))
            },
            input("hover", engine: engine, announce: { _, answer in .from(kind: .hover, answer: answer) },
                  after: { tab, answer in await Self.movePointer(engine, tab, to: answer) }) {
                BrowserPageScripts.hover(try Self.string($0, "selector"))
            },
            input("scroll_into_view", engine: engine) { BrowserPageScripts.scrollIntoView(try Self.string($0, "selector")) },
            // A page scroll (no selector) points at the viewport's middle.
            input("scroll", engine: engine, announce: { _, answer in .from(kind: .scroll, answer: answer) }) { call in
                let params = call.request.params
                let dx = try Self.offset(call, "dx"), dy = try Self.offset(call, "dy")
                guard params["dx"] != nil || params["dy"] != nil else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.scrollOffset", "browser.page.scroll needs params.dx or params.dy"))
                }
                return BrowserPageScripts.scroll(Self.optionalString(call, "selector"), dx: dx, dy: dy)
            },
            input("select", engine: engine, announce: { call, answer in
                .from(kind: .select, answer: answer, text: call.request.params["value"]?.stringValue, replace: true)
            }) { call in
                // An empty value is an option too, so this is not Self.string.
                guard let value = call.request.params["value"]?.stringValue else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@",
                                                                           call.request.method, "value"))
                }
                return BrowserPageScripts.select(try Self.string(call, "selector"), value: value)
            },
            input("check", engine: engine, announce: { _, answer in .from(kind: .check, answer: answer) }) {
                BrowserPageScripts.check(try Self.string($0, "selector"), true)
            },
            input("uncheck", engine: engine, announce: { _, answer in .from(kind: .check, answer: answer) }) {
                BrowserPageScripts.check(try Self.string($0, "selector"), false)
            },
        ]
    }

    /// `announce` turns a successful answer into the agent input the agent
    /// cursor draws (nil: none).
    private func input(_ name: String, engine: any BrowserPageEngine,
                       announce: @escaping @Sendable (ControlCall, JSONValue) -> BrowserPageAgentInput? = { _, _ in nil },
                       after: (@Sendable (Tab, JSONValue) async -> Void)? = nil,
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
            await after?(tab, value)
            if let input = announce(call, value) {
                await engine.announce(Self.attributed(input, call), tabID: tab.id)
            }
            var result = Self.base(tab)
            result["value"] = value["value"] ?? .null
            return .object(result)
        }
    }

    /// Moves the engine's own pointer to the middle of the element a script
    /// measured (`answer.at`, viewport CSS px), so CSS `:hover` matches and
    /// hover menus open as for a person; the script's events alone never
    /// set `:hover`. Best effort: an engine without native input, or an
    /// element with no box, keeps the script's events only.
    static func movePointer(_ engine: any BrowserPageEngine, _ tab: Tab, to answer: JSONValue) async {
        guard let at = answer["at"], let x = at["x"]?.doubleValue, let y = at["y"]?.doubleValue,
              let w = at["w"]?.doubleValue, let h = at["h"]?.doubleValue, w > 0, h > 0 else { return }
        let move = BrowserPageInput.mouse(kind: .move, x: (x + w / 2).rounded(), y: (y + h / 2).rounded(),
                                          button: .left, clickCount: 0, modifiers: [])
        _ = try? await run(engine, .input(move), tab)
    }

    /// `input` as its agent sent it: `params.agent`'s name, from the
    /// request's caller (``BrowserPageAgentOrigin``).
    static func attributed(_ input: BrowserPageAgentInput, _ call: ControlCall) -> BrowserPageAgentInput {
        input.by(optionalString(call, "agent"),
                 from: BrowserPageAgentOrigin.resolve(params: call.request.params, topology: call.snapshot.topology))
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
