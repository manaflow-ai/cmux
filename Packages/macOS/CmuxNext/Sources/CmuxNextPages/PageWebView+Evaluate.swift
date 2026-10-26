public import Foundation
import WebKit

/// Why ``PageWebView/callPageScript(_:arguments:)`` returned no value from a Chromium page.
public nonisolated enum PageScriptError: Error, Sendable, Equatable {
    /// An argument is not a JSON value.
    case argument(String)
    /// The page's answer was not JSON.
    case noResult
    /// The script threw; the text is Chromium's exception description.
    case exception(String)
}

extension PageWebView {
    /// Runs `body` as the body of an async function in the page's main frame, with `arguments` as
    /// its named parameters, in whichever engine shows the page: WebKit's `callAsyncJavaScript`, or
    /// the Chromium page's ``PageChromiumPage/evaluate(_:)``, which awaits the promise. Returns the
    /// function's result as a Foundation value (strings, numbers, Bools, arrays, dictionaries).
    ///
    /// - Parameters:
    ///   - body: A function body that may `await` and `return`.
    ///   - arguments: Its parameters by name; each must be a JSON value (NSNull for null).
    /// - Returns: The returned value; nil for `undefined` or `null`.
    public func callPageScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
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
        let json = try await page.evaluate(expression)
        return try await ChromiumPageHostWire.value(json: json)
    }
}

/// ``PageChromiumPage/evaluate(_:)``'s answer: the script's value as JSON, `null` for null and for
/// undefined. Both are parsed off the caller's actor: a page's text can be megabytes of JSON, and
/// the caller is the main actor (CEF's UI thread).
nonisolated extension ChromiumPageHostWire {
    /// The value JSON of a `Runtime.evaluate` reply (with `returnByValue`), as `tabEvaluate` gives
    /// it (`CEFEvaluationResult`).
    ///
    /// - Parameter reply: The DevTools reply.
    /// - Returns: The value as JSON; `null` for undefined or a reply with no result.
    /// - Throws: ``PageScriptError/exception(_:)`` with the exception's description,
    ///   ``PageScriptError/noResult`` for a reply that is not JSON.
    @concurrent
    static func valueJSON(devToolsReply reply: String) async throws(PageScriptError) -> String {
        guard let object = object(reply) else { throw .noResult }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw .exception(exception?["description"] as? String ?? details["text"] as? String ?? "exception")
        }
        guard let result = object["result"] as? [String: Any], let value = result["value"] else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { throw .noResult }
        return text
    }

    /// The Foundation value of a value JSON, as a `Runtime.evaluate` reply's `value` was: nil for
    /// null (and so for undefined).
    ///
    /// - Parameter json: The value as JSON.
    /// - Returns: The value; nil for `null`.
    /// - Throws: ``PageScriptError/noResult`` when the text is not JSON.
    @concurrent
    static func value(json: String) async throws(PageScriptError) -> sending Any? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            throw .noResult
        }
        return value is NSNull ? nil : value
    }
}
