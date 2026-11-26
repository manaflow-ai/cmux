public import Foundation
public import WebKit

/// Receives unsaved form input from the injected
/// ``WKUserScript/browserFormStateObserver()`` and forwards it to the
/// owning panel on the main actor.
///
/// A thin `NSObject` adapter so the panel never conforms to
/// `WKScriptMessageHandler` itself. It is bound to one web view: a popup the
/// page opens is built from the opener's configuration and shares its content
/// controller, so the popup's reports reach this handler too and are dropped.
@MainActor
public final class BrowserFormStateMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let onReport: @MainActor (BrowserFormStateSnapshot) -> Void

    public init(
        webView: WKWebView,
        onReport: @escaping @MainActor (BrowserFormStateSnapshot) -> Void
    ) {
        self.webView = webView
        self.onReport = onReport
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              message.webView === webView,
              let snapshot = BrowserFormStateSnapshot(messageBody: message.body) else { return }
        // WebKit delivers script messages on the main thread, in order with
        // navigation callbacks, so a report sent by a document before it
        // navigates away lands before the next document's commit resets it.
        onReport(snapshot)
    }
}
