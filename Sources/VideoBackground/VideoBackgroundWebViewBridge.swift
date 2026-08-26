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

    /// Invoked when the embed page finishes loading and again when the
    /// YouTube player reports ready. Scripts evaluated before either point
    /// land in a document that has no player yet, so the host replays its
    /// desired pause state here instead of trusting earlier evaluations.
    @MainActor var onPlayerReady: (@MainActor () -> Void)?

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            #if DEBUG
            cmuxDebugLog("videoBackground.page.didFinish url=\(webView.url?.absoluteString ?? "nil")")
            #endif
            onPlayerReady?()
        }
    }

    /// WebKit can jettison the content process (memory pressure, crash); the
    /// page would silently stay blank, so treat it like any other player failure.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            onPlayerError("web-content-process-terminated")
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers script messages on the main thread; apply synchronously
        // to preserve delivery order relative to navigation callbacks.
        MainActor.assumeIsolated {
            handleScriptEvent(message.body)
        }
    }

    /// Applies one `{event, code}` payload posted by the embed page.
    @MainActor
    func handleScriptEvent(_ body: Any) {
        guard let body = body as? [String: Any],
              let event = body["event"] as? String else { return }
        let code = body["code"].map { "\($0)" } ?? "unknown"
        #if DEBUG
        cmuxDebugLog("videoBackground.page.event=\(event) code=\(code)")
        #endif
        switch event {
        case "error":
            onPlayerError("player-error: \(code)")
        case "ready":
            onPlayerReady?()
        default:
            // "skipped" is informational; nothing to do.
            break
        }
    }
}
