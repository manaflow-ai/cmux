import Foundation
import WebKit

/// Receives the page's `agentSession` messages. The user content controller
/// retains its handlers, so this holds the view weakly to break the cycle.
///
/// Trust: only the main frame of this pane's web view, showing the bundled
/// page, may ask for the handshake (it carries the daemon token). Anything
/// else is refused before the model sees it.
final class AgentPaneBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var view: AgentPaneView?

    init(view: AgentPaneView) {
        self.view = view
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let view, message.webView === view.webView, message.frameInfo.isMainFrame,
              Self.isTrusted(message.frameInfo.request.url, page: view.pageURL)
        else {
            return (AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame"), nil)
        }
        let reply = await view.model.respond(to: AgentPaneRequest(body: message.body))
        return (reply, nil)
    }

    /// True when `url` is the bundled page itself (a `#fragment` allowed).
    static func isTrusted(_ url: URL?, page: URL) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path == page.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
