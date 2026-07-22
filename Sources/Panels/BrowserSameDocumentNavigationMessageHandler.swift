import Foundation
import WebKit

/// Bridges authoritative same-document events from the active main-frame document.
@MainActor
final class BrowserSameDocumentNavigationMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxSameDocumentNavigation"
    static let contentWorld = WKContentWorld.world(name: "cmux.browser.same-document-navigation")

    static let userScript = WKUserScript(
        source: """
        (() => {
          const reportNavigation = (event) => {
            // The isolated content world hides the handler from page script;
            // isTrusted also rejects synthetic events dispatched by the page.
            if (!event.isTrusted) return;
            window.webkit.messageHandlers['\(name)'].postMessage(window.location.href);
          };
          window.addEventListener('hashchange', reportNavigation, true);
          window.addEventListener('popstate', reportNavigation, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: contentWorld
    )

    private weak var webView: WKWebView?
    private let onNavigation: @MainActor (URL) -> Void

    init(
        webView: WKWebView,
        onNavigation: @escaping @MainActor (URL) -> Void
    ) {
        self.webView = webView
        self.onNavigation = onNavigation
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              message.webView === webView,
              let value = message.body as? String,
              let url = URL(string: value) else {
            return
        }
        onNavigation(url)
    }
}
