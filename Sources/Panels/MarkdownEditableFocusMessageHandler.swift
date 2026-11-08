import WebKit

@MainActor
final class MarkdownEditableFocusMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxMarkdownEditableFocus"
    static let shared = MarkdownEditableFocusMessageHandler()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let webView = message.webView as? MarkdownWebView,
              let body = message.body as? [String: Any],
              let editable = body["editable"] as? Bool else { return }
        webView.markdownEditableFocusDidChange(editable)
    }
}
