import Foundation
import WebKit

/// One-shot page-world bridge used only while a strict-CSP browser expression
/// is waiting for an asynchronous result.
final class BrowserEvalResultMessageHandler: NSObject, WKScriptMessageHandler {
    private let expectedWebViewIdentifier: ObjectIdentifier
    private let onMessage: @MainActor (Any) -> Void

    init(
        expectedWebViewIdentifier: ObjectIdentifier,
        onMessage: @escaping @MainActor (Any) -> Void
    ) {
        self.expectedWebViewIdentifier = expectedWebViewIdentifier
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit delivers script messages on the main thread. Keep the one-shot
        // completion ordered with handler removal and reject subframe reports.
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame,
                  let webView = message.webView,
                  ObjectIdentifier(webView) == expectedWebViewIdentifier else { return }
            onMessage(message.body)
        }
    }
}
