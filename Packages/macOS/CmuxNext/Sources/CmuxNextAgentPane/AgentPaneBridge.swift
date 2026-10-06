import Foundation
import os
import WebKit

/// Receives the page's `agentSession` messages. The user content controller
/// retains its handlers, so this holds the view weakly to break the cycle.
///
/// Trust: only the main frame of this pane's web view, showing the pane's
/// own page (`AgentPaneSource.isTrusted`), may ask for the handshake (it
/// carries the daemon token). Anything else is refused before the model
/// sees it.
final class AgentPaneBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.bridge")
    weak var view: AgentPaneView?

    init(view: AgentPaneView) {
        self.view = view
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard isTrusted(message) else {
            logger.error("agent pane message rejected as untrusted name=\(message.name, privacy: .public) url=\(message.frameInfo.request.url?.absoluteString ?? "", privacy: .public)")
            return replyHandler(AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame"), nil)
        }
        let request = AgentPaneRequest(body: message.body)
        // A page frame for the host's socket goes out on this turn when it can (no Task hop).
        if case .transportSend(let connection, let frames) = request, let model = view?.model {
            return model.transport.submit(connection: connection, frames: frames) { error in
                replyHandler(AgentPaneModel.transportReply(error), nil)
            }
        }
        // Transport requests carry chat content and run per batch: not logged.
        if !request.isTransport {
            logger.info("agent pane trusted message request=\(String(describing: request), privacy: .public) url=\(message.frameInfo.request.url?.absoluteString ?? "", privacy: .public)")
        }
        // task-owner: one page request; its reply goes back through replyHandler
        Task { replyHandler(await self.reply(to: request), nil) }
    }

    /// The reply for a request from the pane's trusted page.
    func reply(to request: AgentPaneRequest) async -> [String: Any] {
        guard let model = prepare(for: request) else { return AgentPaneReply.failure(code: "closed", message: "Closed") }
        // The handshake can wait up to 20 seconds for acpmux to start. Only
        // the model is held across it, so closing the tab frees the view and
        // its web view right away.
        return await model.respond(to: request)
    }

    private func isTrusted(_ message: WKScriptMessage) -> Bool {
        guard let view else { return false }
        return message.webView === view.webView && message.frameInfo.isMainFrame
            && view.source.isTrusted(message.frameInfo.request.url)
    }

    private func prepare(for request: AgentPaneRequest) -> AgentPaneModel? {
        guard let view else { return nil }
        // The page installs its bridge and registry before asking for the
        // handshake, which can be after didFinish, where the theme and
        // customization were first pushed; push them again so they land.
        if request == .ready {
            logger.info("agent pane ready accepted")
            view.applyTheme()
            view.applyShortcuts()
            view.applyPreviewFeatures()
            view.replayCustomization()
        }
        return view.model
    }
}
