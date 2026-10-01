import Foundation
import WebKit

/// Receives the page's `agentSession` messages. The user content controller
/// retains its handlers, so this holds the view weakly to break the cycle.
///
/// Trust: only the main frame of this pane's web view, showing the pane's
/// own page (`AgentPaneSource.isTrusted`), may ask for the handshake (it
/// carries the daemon token). Anything else is refused before the model
/// sees it.
final class AgentPaneBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var view: AgentPaneView?

    init(view: AgentPaneView) {
        self.view = view
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let view, message.webView === view.webView, message.frameInfo.isMainFrame,
              view.source.isTrusted(message.frameInfo.request.url)
        else {
            return (AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame"), nil)
        }
        return (await reply(to: AgentPaneRequest(body: message.body)), nil)
    }

    /// The reply for a request from the pane's trusted page.
    func reply(to request: AgentPaneRequest) async -> [String: Any] {
        guard let view else { return AgentPaneReply.failure(code: "closed", message: "Closed") }
        // The page installs its bridge and registry before asking for the
        // handshake, which can be after didFinish; replay the customization
        // so registry.js finds them.
        if request == .ready { view.replayCustomization() }
        return await view.model.respond(to: request)
    }
}
