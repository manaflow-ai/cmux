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
    /// The page shows in Chromium and has not started yet (it starts on its first show,
    /// PageWebView+ChromiumCost.swift): there is no document to run the script in. Not an answer
    /// of the page, so a caller can tell it from a script that returned `null`.
    case notStarted
}

extension PageWebView {
    /// Runs `body` as the body of an async function in the page's main frame, with `arguments` as
    /// its named parameters, in whichever engine shows the page: WebKit's `callAsyncJavaScript`, or
    /// Chromium's `Runtime.evaluate` awaiting the promise. Returns the function's result as a
    /// Foundation value (strings, numbers, Bools, arrays, dictionaries).
    ///
    /// - Parameters:
    ///   - body: A function body that may `await` and `return`.
    ///   - arguments: Its parameters by name; each must be a JSON value (NSNull for null).
    /// - Returns: The returned value; nil for `undefined` or `null`.
    /// - Throws: ``PageScriptError/notStarted`` for a Chromium page that has not started yet; the
    ///   engine's error when the script fails.
    public func callPageScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let page = awakeChromiumPage else {
            guard let webView = documentWebView else { throw PageScriptError.notStarted }
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
