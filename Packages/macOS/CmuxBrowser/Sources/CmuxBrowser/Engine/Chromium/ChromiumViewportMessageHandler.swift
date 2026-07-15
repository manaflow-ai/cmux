import Foundation
import WebKit

/// Forwards local viewport input messages to its Chromium engine session.
@MainActor
final class ChromiumViewportMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: ChromiumBrowserEngineSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        session?.handleViewportMessage(payload)
    }
}
