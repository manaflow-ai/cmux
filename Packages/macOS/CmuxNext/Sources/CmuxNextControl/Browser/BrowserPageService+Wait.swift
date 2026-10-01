public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// `browser.page.wait` and `browser.page.screenshot`.
extension BrowserPageService {
    /// `timeout_ms` when the request names none (the old `cmux browser wait`).
    static let defaultWaitMilliseconds = 5_000
    static let maximumWaitMilliseconds = 120_000
    /// One page wait lasts at most this long, then starts again for the rest
    /// of the time: Chromium's DevTools calls end after 5 s, and a promise
    /// WebKit never settles (a navigation) cannot hold the wait.
    static let pageWaitChunkMilliseconds = 4_000
    /// A full-page capture scrolls and snapshots the page tile by tile.
    static let screenshotDeadline: Duration = .seconds(30)

    func waitAndCaptureMethods() -> [ControlMethod] {
        let engine = engine
        return [
            .async("browser.page.wait") { call in
                let tab = try Self.tab(call)
                let condition = try Self.waitCondition(call)
                let timeoutMs = try Self.waitTimeout(call)
                try await Self.waitUntil(engine, tab, condition, timeoutMs: timeoutMs, method: call.method)
                var result = Self.base(tab)
                result["waited"] = true
                return .object(result)
            }.withDeadline(.fixed(.milliseconds(Self.maximumWaitMilliseconds) + .seconds(3))),
            .async("browser.page.screenshot") { call in
                let tab = try Self.tab(call)
                let params = call.request.params
                let selector = params["selector"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let fullPage = params["full_page"]?.boolValue == true
                let capture: BrowserPageCapture
                switch (selector, fullPage) {
                case (.some, true):
                    throw ControlError.invalidParams(ControlStrings.text("control.error.screenshotSelectorOrFullPage",
                                                                         "browser.page.screenshot takes params.selector or params.full_page, not both"))
                case (.some(let selector), false):
                    capture = .clip(try await Self.clip(engine, tab, selector))
                case (nil, true): capture = .fullPage
                case (nil, false): capture = .viewport
                }
                let shot = try await Self.run(engine, .screenshot(capture), tab)
                var result = Self.base(tab)
                for key in ["path", "png_base64", "width", "height"] { result[key] = shot[key] ?? .null }
                if let selector { result["selector"] = .string(selector) }
                return .object(result)
            }.withDeadline(.fixed(Self.screenshotDeadline)),
        ]
    }

    static func waitCondition(_ call: ControlCall) throws -> BrowserPageScripts.WaitCondition {
        let params = call.request.params
        func text(_ key: String) -> String? { params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        if let selector = text("selector") { return .selector(selector) }
        if let url = text("url_contains") { return .urlContains(url) }
        if let needle = text("text_contains") { return .textContains(needle) }
        if let state = text("load_state")?.lowercased() {
            guard ["interactive", "complete"].contains(state) else {
                throw ControlError.invalidParams(ControlStrings.format("control.error.waitLoadState",
                                                                      "load_state must be interactive or complete, not %@", state))
            }
            return .loadState(state)
        }
        if let expression = text("function") { return .function(expression) }
        return .loadState("complete")
    }

    static func waitTimeout(_ call: ControlCall) throws -> Int {
        guard let raw = call.request.params["timeout_ms"], raw != .null else { return defaultWaitMilliseconds }
        guard let value = raw.intValue, (1...maximumWaitMilliseconds).contains(value) else {
            throw ControlError.invalidParams(ControlStrings.format("control.error.waitTimeoutRange",
                                                                  "timeout_ms must be a whole number from 1 to %@", String(maximumWaitMilliseconds)))
        }
        return value
    }

    /// Waits in the page until `condition` holds, in page waits of at most
    /// ``pageWaitChunkMilliseconds``. A navigation ends the page's wait with
    /// an engine error; the wait then starts again in the new page, spaced
    /// by ``Backoff``, for the rest of the time.
    static func waitUntil(_ engine: any BrowserPageEngine, _ tab: Tab, _ condition: BrowserPageScripts.WaitCondition,
                          timeoutMs: Int, method: String) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        var backoff = Backoff(initial: .milliseconds(50), maximum: .milliseconds(500))
        var lastError: String?
        while ContinuousClock.now < deadline {
            // A disconnected client cancels the handler; the chunk deadline does not see it.
            try Task.checkCancellation()
            let remaining = Int(((deadline - .now).inSeconds * 1000).rounded(.up))
            let chunk = min(remaining, pageWaitChunkMilliseconds)
            let started = ContinuousClock.now
            do {
                // The page's own timer ends the wait; this bounds an engine that never answers.
                let value = try await ControlDeadline.run(method: method, deadline: .now + .milliseconds(chunk) + .seconds(1)) {
                    try await Self.run(engine, .evaluateAsync(BrowserPageScripts.waitScript(condition, timeoutMs: chunk)), tab)
                }["value"]
                if value?["met"]?.boolValue == true { return }
                lastError = value?["error"]?.stringValue ?? lastError
                // A page wait that ended before its timer did not wait (no answer, a
                // page that is not running yet): space the next one.
                if ContinuousClock.now - started < .milliseconds(chunk) {
                    // concurrency-allow: Backoff's async sleep spaces retries after a failure; it blocks no thread
                    try await backoff.wait(owner: method)
                }
            } catch let error as ControlError where error.code == "js_error" && error.message.contains("SyntaxError") {
                throw ControlError(code: "js_error",
                                   message: ControlStrings.format("control.error.waitCondition", "Wait condition could not be evaluated: %@", error.message),
                                   data: ["timeout_ms": JSONValue(timeoutMs)])
            } catch let error as ControlError where ["js_error", "app_error", "unavailable", "timeout"].contains(error.code) {
                // The page navigated, is still starting, or never answered. The loop ends at the deadline.
                lastError = error.message
                // concurrency-allow: Backoff's async sleep spaces retries after a failure; it blocks no thread
                try await backoff.wait(owner: method)
            }
        }
        var data: [String: JSONValue] = ["timeout_ms": JSONValue(timeoutMs)]
        if let lastError { data["last_error"] = .string(lastError) }
        throw ControlError(code: "timeout", message: ControlStrings.text("control.error.waitTimeout", "Condition not met before timeout"), data: .object(data))
    }

    static func clip(_ engine: any BrowserPageEngine, _ tab: Tab, _ selector: String) async throws -> BrowserPageClip {
        let value = try await run(engine, .evaluate(BrowserPageScripts.elementClip(selector)), tab)["value"] ?? .null
        if let error = value["error"]?.stringValue {
            throw ControlError(code: "not_found", message: error, data: ["selector": .string(selector)])
        }
        let rect = value["value"] ?? .null
        func number(_ key: String) -> Double { rect[key]?.doubleValue ?? 0 }
        return BrowserPageClip(x: number("x"), y: number("y"), width: number("width"), height: number("height"),
                               viewportWidth: number("viewport_width"), viewportHeight: number("viewport_height"))
    }
}
