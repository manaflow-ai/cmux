import WebKit

@MainActor
final class DiffViewerEditableFocusMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxDiffViewerEditableFocus"
    static let contentWorld = WKContentWorld.world(name: "cmuxDiffViewerNavigation")
    static let shared = DiffViewerEditableFocusMessageHandler()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard DiffCommentsBridge.isTrustedDiffViewerFrame(message.frameInfo),
              let webView = message.webView as? CmuxWebView,
              let body = message.body as? [String: Any],
              let viewer = body["viewer"] as? Bool,
              let editable = body["editable"] as? Bool,
              let rendererReady = body["rendererReady"] as? Bool else { return }
        webView.diffViewerFocusStateDidChange(
            viewer: viewer,
            editable: editable,
            rendererReady: rendererReady
        )
    }
}
