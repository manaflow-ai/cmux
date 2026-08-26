import Foundation
import WebKit
import CmuxBrowser

/// Navigation policy and script-message adapter for the video background
/// webview.
///
/// Mirrors ``BrowserMediaPlaybackMessageHandler``: a thin `NSObject` adapter so
/// the player view never conforms to WebKit delegate protocols itself. The
/// navigation policy pins the main frame to the generated embed page — the
/// layer is not a browser, so any other main-frame navigation is cancelled —
/// while YouTube's own iframe keeps full subframe freedom.
final class VideoBackgroundWebViewBridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let onPlayerError: @MainActor (String) -> Void

    init(onPlayerError: @escaping @MainActor (String) -> Void) {
        self.onPlayerError = onPlayerError
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        let url = navigationAction.request.url
        let isEmbedPageLoad = url?.host == VideoBackgroundEmbedPage.baseURL.host
            || url?.scheme == "about"
        decisionHandler(isEmbedPageLoad ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        MainActor.assumeIsolated {
            onPlayerError("provisional-navigation-failed: \((error as NSError).code)")
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        let code = body["code"].map { "\($0)" } ?? "unknown"
        // WebKit delivers script messages on the main thread; apply synchronously
        // to preserve delivery order relative to navigation callbacks.
        MainActor.assumeIsolated {
            switch event {
            case "error":
                onPlayerError("player-error: \(code)")
            default:
                // "ready" and "skipped" are informational; nothing to do.
                break
            }
        }
    }
}
