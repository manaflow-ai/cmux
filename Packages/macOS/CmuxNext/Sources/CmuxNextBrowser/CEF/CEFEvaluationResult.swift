import Foundation

/// A `cmux_shim_tab_evaluate` answer (EVALUATE_RESULT, fork API 29), before it is parsed.
nonisolated struct CEFEvaluationResult: Equatable, Sendable {
    /// 1 value, 0 exception, -1 no result (the renderer ended, the page navigated away, the frame
    /// went), -2 the shim refused the world name.
    var status: Int
    /// The value as JSON (Runtime.evaluate returnByValue rules; empty for undefined), or the
    /// exception's text.
    var text: String

    /// The script's value. Parsed off the caller's actor: a value can be megabytes of JSON, and
    /// the event arrives on CEF's UI thread, cmux's main thread.
    @concurrent
    func value() async throws(BrowserTabError) -> BrowserJSValue {
        switch status {
        case 1:
            guard !text.isEmpty else { return .null }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
                throw .javaScript("invalid script result")
            }
            return BrowserJSValue(foundation: object)
        case 0: throw .javaScript(text.isEmpty ? "exception" : text)
        case -2: throw .javaScript("refused script world")
        default: throw .closed
        }
    }
}
