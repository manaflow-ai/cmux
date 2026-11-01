import Foundation
import CmuxNextPages
import CmuxNextSettings
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
        // A right-click menu of the page shows as a standard macOS menu; the reply waits for it to close.
        if let body = message.body as? [String: Any], body["method"] as? String == AgentPaneView.contextMenuMethod, let view {
            return view.contextMenu(params: body["params"] as? [String: Any] ?? [:]) { replyHandler($0, nil) }
        }
        // A page menu with no room in the pane draws past the window's edge (AgentPaneView+Popup).
        if let body = message.body as? [String: Any], let method = body["method"] as? String, method.hasPrefix("popup."),
           let view {
            return replyHandler(view.popup(method, params: body["params"] as? [String: Any] ?? [:]), nil)
        }
        // Where a chat rests belongs to the chat, so it is answered here from the one store both
        // hosts share and never reaches the model (AgentPaneScrollAnchors+Bridge). Not logged: it
        // names a row of the person's transcript.
        if let reply = Self.chatPlaceReply(for: message.body) {
            return replyHandler(reply, nil)
        }
        // What a page last read of a chat, for the next tab that opens it (``AgentPaneTailCache``):
        // the chat's, not the pane's, so it never reaches the model, and never logged (it is the
        // chat's text).
        if let body = message.body as? [String: Any], let method = body["method"] as? String,
           AgentPaneTailCache.handles(method: method) {
            return replyHandler(AgentPaneTailCache.reply(to: method, params: body["params"] as? [String: Any]), nil)
        }
        let request = AgentPaneRequest(body: message.body)
        if case .uiPointerReport(let text) = request, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let json = JSONValue(foundation: value), let view {
            view.uiPointerReport?(json)
            return replyHandler(["ok": true], nil)
        }
        // A page frame for the host's socket goes out on this turn when it can (no Task hop).
        if case .transportSend(let connection, let frames) = request, let model = view?.model {
            return model.transport.submit(connection: connection, frames: frames) { error in
                replyHandler(AgentPaneModel.transportReply(error), nil)
            }
        }
        // Transport and shell requests carry chat content or commands and run often, a tool card's
        // typed value is a secret, and an upload carries the person's files: not logged.
        if !request.isTransport, !request.isShell, !request.carriesEntered, !request.carriesFiles {
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
        guard request == .ready else { return await model.respond(to: request) }
        AgentPaneLaunchTimings.shared.mark("agent_pane.handshake_start")
        defer { AgentPaneLaunchTimings.shared.mark("agent_pane.handshake_end") }
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
        // customization were first pushed; push them again so they land. The New Tab page's chats
        // and closed items are set when the view is made, before the page loads (cx-uw104).
        if request == .ready {
            logger.info("agent pane ready accepted")
            view.refreshQuestionKeyBinding()
            view.applyTheme(force: true)
            // This document has no composer state, even when the native value has not changed.
            view.deliver([.composer(view.model.composer)], scripts: [view.model.composer.pageScript])
            view.applyShortcuts()
            view.applyPreviewFeatures()
            AgentPaneSessionStatus.push(to: view)
            AgentPaneSuggestedTasks.shared.push(to: view)
            view.model.remoteControl?.push(to: view)
            view.applyEditedFiles()
            if view.pageEvents == nil { view.model.sidebarPreviewVariant.replay(to: view) }
            view.replayCustomization()
            AgentPaneToolCard.replay(to: view)
            AgentPaneComputerUsePreview.replay(to: view)
            AgentPaneDeviceChat.push(view.deviceChats, to: view)
            AgentPaneClosedItem.push(view.recentlyClosed, to: view)
            AgentPaneNowPlaying.shared.push(to: view)
            view.model.readAloud?.push(to: view)
        }
        return view.model
    }
}
