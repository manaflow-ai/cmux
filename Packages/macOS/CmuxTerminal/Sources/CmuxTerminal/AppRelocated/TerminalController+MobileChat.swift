import CmuxAgentChat
import CmuxTerminal
import Foundation

/// `mobile.chat.*` RPC entrypoints on the data-plane god object.
///
/// The chat dispatch logic now lives in ``MobileChatRPCHandler``; this file is
/// the thin seam between it and ``TerminalController``: the handler reaches the
/// terminal data plane (transcript service, workspace/surface resolution,
/// terminal paste, v2 param/error vocabulary) only through the
/// ``MobileChatRPCHost`` conformance below, and the few entrypoints other
/// callers still drive (`mobileHostHandleRPC`, the debug `chat.sessions.dump`
/// command, and the title-change adoption observer) forward to the owned
/// handler. The send/interrupt/answer paths reuse the existing mobile terminal
/// injection machinery so chat input behaves exactly like composer input.
extension TerminalController {
    /// The owned `mobile.chat.*` dispatch handler. Built lazily so it captures
    /// `self` as its host seam after the controller is fully constructed; the
    /// transcript service it reads is resolved through the seam at call time, so
    /// the late `attachAuth`-time wiring of `agentChatTranscriptService` is
    /// observed correctly.
    var mobileChatHandler: MobileChatRPCHandler {
        if let existing = mobileChatHandlerStorage {
            return existing
        }
        let handler = MobileChatRPCHandler(host: self)
        mobileChatHandlerStorage = handler
        return handler
    }

    /// Routes one `mobile.chat.*` method to the owned handler (single dispatch
    /// case in `mobileHostHandleRPC` keeps the god-file growth flat).
    func v2MobileChatDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        await mobileChatHandler.dispatch(method: method, params: params)
    }

    /// `chat.sessions.dump` (local debug socket, main-actor lane): the full
    /// chat-session registry state, for diagnosing inconsistent phone-side
    /// states.
    func v2ChatSessionsDump() -> V2CallResult {
        mobileChatHandler.sessionsDump()
    }

    /// Scans a workspace's terminals for a running coding agent with no chat
    /// session yet and adopts it. Called live from the terminal title-change
    /// observer (via workspace id) and the mobile session-list RPC.
    func adoptDetectedAgentSessions(workspaceID: String) {
        mobileChatHandler.adoptDetectedAgentSessions(workspaceID: workspaceID)
    }

    /// Workspace-typed adoption entrypoint for callers that already hold the
    /// `Workspace` (the workspace-list RPC enumerates every workspace and adopts
    /// inline).
    func adoptDetectedAgentSessions(workspace: Workspace) {
        mobileChatHandler.adoptDetectedAgentSessions(workspace: workspace)
    }
}

// MARK: - MobileChatRPCHost

extension TerminalController: MobileChatRPCHost {
    var mobileChatTranscriptService: AgentChatTranscriptService? {
        agentChatTranscriptService
    }

    func mobileChatResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (workspace: Workspace, surfaceId: UUID?)? {
        guard let resolved = mobileResolveWorkspaceAndSurface(
            params: params,
            requireTerminal: requireTerminal
        ) else { return nil }
        return (workspace: resolved.workspace, surfaceId: resolved.surfaceId)
    }

    func mobileChatPasteText(params: [String: Any]) -> V2CallResult {
        v2MobileTerminalPaste(params: params)
    }

    func mobileChatPasteImage(params: [String: Any]) -> V2CallResult {
        v2MobileTerminalPasteImage(params: params)
    }

    func mobileChatStringParam(_ params: [String: Any], _ key: String) -> String? {
        v2String(params, key)
    }

    func mobileChatRawStringParam(_ params: [String: Any], _ key: String) -> String? {
        v2RawString(params, key)
    }

    func mobileChatIntParam(_ params: [String: Any], _ key: String) -> Int? {
        v2Int(params, key)
    }

    var mobileChatInputQueueFullMessage: String { Self.terminalInputQueueFullMessage }
    var mobileChatSurfaceUnavailableMessage: String { Self.terminalSurfaceUnavailableMessage }
    var mobileChatProcessExitedMessage: String { Self.terminalProcessExitedMessage }
}
