public import WebKit

/// Keeps page scripts in a tab a REPL session created from writing the
/// system clipboard. Not implemented yet: ``install(on:shim:onWrite:)`` does
/// nothing.
@MainActor
public enum BrowserReplPageClipboard {
    /// The page-world script message handler `page-clipboard.js` posts to.
    public static let messageHandlerName = "cmuxBrowserReplClipboard"

    /// Installs the guard on `webView`. Does nothing yet.
    ///
    /// - Parameters:
    ///   - shim: the source of `Resources/browser-repl/page-clipboard.js`.
    ///   - onWrite: receives the web view a page wrote from and its items
    ///     (`[["type": String, "base64": String]]`); returns whether a tab's
    ///     clipboard took them.
    /// - Returns: whether WebKit's asynchronous Clipboard API is off.
    @discardableResult
    public static func install(
        on webView: WKWebView,
        shim: String,
        onWrite: @escaping @MainActor (_ webView: WKWebView, _ items: [[String: Any]]) -> Bool
    ) -> Bool {
        _ = webView
        _ = shim
        _ = onWrite
        return false
    }
}
