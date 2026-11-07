import CmuxNextWakeups
public import Foundation
import WebKit

/// Why ``PageWebView/callPageScript(_:arguments:)`` returned no value from a Chromium page.
public nonisolated enum PageScriptError: Error, Sendable, Equatable {
    /// An argument is not a JSON value.
    case argument(String)
    /// The DevTools reply was not JSON.
    case noResult
    /// The script threw; the text is Chromium's exception description.
    case exception(String)
}

extension PageWebView {
    /// Runs `body` as the body of an async function in the page's main frame, with `arguments` as
    /// its named parameters, in whichever engine shows the page: WebKit's `callAsyncJavaScript`, or
    /// Chromium's `Runtime.evaluate` awaiting the promise. Returns the function's result as a
    /// Foundation value (strings, numbers, Bools, arrays, dictionaries). A call made while the Chromium
    /// page is still starting waits for it (or for its fallback to WebKit), at most
    /// ``chromiumScriptWait``; a start that has not ended by then returns nil.
    ///
    /// - Parameters:
    ///   - body: A function body that may `await` and `return`.
    ///   - arguments: Its parameters by name; each must be a JSON value (NSNull for null).
    /// - Returns: The returned value; nil for `undefined` or `null`.
    public func callPageScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        // While the Chromium page is still being made, no engine shows the page: the WebKit view is
        // hidden and never loads the document, so a call there waited on a page that never came (the
        // chat-open bench's `layout_watch` answered ~6 s after a cold click, cmuxterm-hq#6338). Wait
        // for the start to attach Chromium or fall back to WebKit, then run in whichever shows it.
        // Bounded: a Chromium page that is never made (CEF never creates the browser) would hold the
        // call for good, where it used to return at once (cmux#34154). It returns nil, as a page with
        // no answer does.
        if chromiumSession == nil, let start = chromiumStart, await !chromiumStartEnded(start) { return nil }
        guard let page = chromiumSession?.page else {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        }
        let names = arguments.keys.sorted()
        let values = try names.map { name in
            guard let value = arguments[name], JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let text = String(data: data, encoding: .utf8) else { throw PageScriptError.argument(name) }
            return text
        }
        let expression = "(async (\(names.joined(separator: ", "))) => {\n\(body)\n})(\(values.joined(separator: ", ")))"
        let json = try await page.devTools("Runtime.evaluate",
                                           params: ["expression": expression, "awaitPromise": true, "returnByValue": true])
        guard let object = ChromiumPageHostWire.object(json) else { throw PageScriptError.noResult }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw PageScriptError.exception(exception?["description"] as? String ?? details["text"] as? String ?? "exception")
        }
        let value = (object["result"] as? [String: Any])?["value"]
        return value is NSNull ? nil : value
    }
}

extension PageWebView {
    /// Waits for `start` (the Chromium start in flight) at most ``chromiumScriptWait`` on
    /// ``chromiumClock``: true when it ended, false when the wait ran out first. The wait for `start`
    /// keeps running after a timeout until the start ends (closing the view cancels it).
    func chromiumStartEnded(_ start: Task<Void, Never>) async -> Bool {
        let timer = DemandTimer(owner: "page.chromium.script-wait", clock: chromiumClock)
        let race = PageStartRace()
        let wait = chromiumScriptWait
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.continuation = continuation
            timer.schedule(after: wait) { @MainActor in race.finish(false) }
            // task-owner: ends with `start`, which the view cancels when it closes or falls back.
            Task { @MainActor in
                await start.value
                timer.cancel()
                race.finish(true)
            }
        }
    }
}

/// The first of a Chromium start and its deadline to end resumes the waiting call, once.
@MainActor
private final class PageStartRace {
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ ended: Bool) {
        continuation?.resume(returning: ended)
        continuation = nil
    }
}
