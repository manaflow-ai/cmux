import Foundation
import WebKit

/// Delivers a document-end signal from an isolated WebKit content world.
///
/// The navigation delegate remains the authoritative lifecycle callback. This bridge is a
/// defensive fallback for WebKit rebinds where the document becomes executable before the native
/// delegate callback reaches the current panel owner. A page cannot access the custom content
/// world, so page JavaScript cannot forge the signal.
@MainActor
final class BrowserDocumentReadyMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxDocumentReady"
    static let contentWorld = WKContentWorld.world(name: "cmux.browser.document-ready")
    static let userScript = WKUserScript(
        source: """
        (() => {
          const publish = () => {
            const state = String(document.readyState || '');
            if (state !== 'interactive' && state !== 'complete') return;
            try {
              window.webkit?.messageHandlers?.['\(name)']?.postMessage(state);
            } catch (_) {}
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', publish, { once: true });
          }
          publish();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true,
        in: contentWorld
    )

    private weak var webView: WKWebView?
    private let onDocumentReady: @MainActor () -> Void

    init(
        webView: WKWebView,
        onDocumentReady: @escaping @MainActor () -> Void
    ) {
        self.webView = webView
        self.onDocumentReady = onDocumentReady
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              message.webView === webView,
              let readyState = message.body as? String,
              readyState == "interactive" || readyState == "complete" else {
            return
        }
        onDocumentReady()
    }
}
