import CmuxBrowser
import WebKit

extension MarkdownRendererSession: BrowserFindScriptEvaluating {
    func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        guard let webView = ownedCoordinator.webView else { return nil }
        return try await webView.evaluateJavaScript(script.source)
    }

    func focusWebView() {
        guard let webView = ownedCoordinator.webView,
              let window = webView.window else { return }
        _ = window.makeFirstResponder(webView)
    }

    func setRenderCompletionHandler(_ handler: @escaping @MainActor () -> Void) {
        ownedCoordinator.onRenderCompleted = handler
    }

    func clearRenderCompletionHandler() {
        ownedCoordinator.onRenderCompleted = nil
    }
}
