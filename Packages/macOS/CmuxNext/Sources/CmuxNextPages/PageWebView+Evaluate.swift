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
    /// page is still starting waits for it (or for its fallback to WebKit).
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
        if chromiumSession == nil, let start = chromiumStart { await start.value }
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
