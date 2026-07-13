import WebKit

@MainActor
final class DiffViewerEditableFocusMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxDiffViewerEditableFocus"
    static let shared = DiffViewerEditableFocusMessageHandler()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              DiffCommentsBridge.diffViewerToken(from: message.frameInfo.request.url) != nil,
              let webView = message.webView as? CmuxWebView,
              let body = message.body as? [String: Any],
              let viewer = body["viewer"] as? Bool,
              let editable = body["editable"] as? Bool else { return }
        webView.diffViewerFocusStateDidChange(viewer: viewer, editable: editable)
    }
}
