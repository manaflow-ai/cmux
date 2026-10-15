/// How an automation script's source is shaped.
public enum BrowserAutomationScriptForm: Sendable, Equatable {
    /// A JavaScript expression; its completion value is the result.
    case expression
    /// The body of an async function; the value it returns (awaited) is the
    /// result. Mirrors WebKit's `callAsyncJavaScript`.
    case asyncFunctionBody
}

extension BrowserPageScriptWorld {
    /// The isolated world browser automation falls back to when page CSP
    /// blocks `eval`. On WebKit pages the socket layer keeps using the
    /// default client world, which is what it used before the engine seam.
    public static let automation = BrowserPageScriptWorld.isolated("cmux-automation")
}
