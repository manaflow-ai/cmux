import CmuxNextCompat
public import Foundation
import WebKit

/// Why ``PageWebView/callPageScript(_:arguments:)`` returned no value.
public nonisolated enum PageScriptError: Error, Sendable, Equatable {
    /// The page has no document yet: it waits for its first show (``PageWebView/awaitsFirstShow``), or
    /// its Chromium page is on its way.
    case notStarted
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
        // No document yet: WebKit would launch the page's WebContent process to run it.
        if awaitsFirstShow { throw PageScriptError.notStarted }
        // MQ12 thaws first: a frozen page cannot answer, and it does not freeze until the answer comes.
        pushes.callStarted()
        defer { pushes.callEnded() }
        // The router envelopes waiting for the frame were sent before it.
        scripts.flush()
        guard let page = chromiumSession?.page else {
            guard let view = webKitPieces?.view else { throw PageScriptError.notStarted }
            return try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        }
        let names = arguments.keys.sorted()
        let values = try names.map { name in
            guard let value = arguments[name], JSONSerialization.isValidJSONObject([value]),
                  let data = try? CheckedJSON.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let text = String(data: data, encoding: .utf8) else { throw PageScriptError.argument(name) }
            return text
        }
        let expression = "(async (\(names.joined(separator: ", "))) => {\n\(body)\n})(\(values.joined(separator: ", ")))"
        let value = try await page.evaluate(expression)
        return value is NSNull ? nil : value
    }

    /// The fragment the document shows now, which follows the page's own links and history (a
    /// section the person picked in the page), unlike ``route``, the last one the host asked for;
    /// ``route`` while no document answers. Nil for a page on its default place (no fragment).
    public func shownRoute() async -> String? {
        guard loaded, let hash = try? await callPageScript("return window.location.hash;") as? String else { return route }
        return hash.isEmpty ? nil : hash
    }
}

nonisolated extension ChromiumPageHostWire {
    /// The value of a `Runtime.evaluate` reply (with `returnByValue`), parsed off the caller's
    /// actor in one step: a page's text can be megabytes of JSON, and the caller is the main actor
    /// (CEF's UI thread).
    ///
    /// - Parameter reply: The DevTools reply.
    /// - Returns: The value; `NSNull` for null, nil for undefined or a reply with no result.
    /// - Throws: ``PageScriptError/exception(_:)`` with the exception's description,
    ///   ``PageScriptError/noResult`` for a reply that is not JSON.
    @concurrent
    static func value(devToolsReply reply: String) async throws(PageScriptError) -> sending Any? {
        guard let object = object(reply) else { throw .noResult }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw .exception(exception?["description"] as? String ?? details["text"] as? String ?? "exception")
        }
        return (object["result"] as? [String: Any])?["value"]
    }
}
