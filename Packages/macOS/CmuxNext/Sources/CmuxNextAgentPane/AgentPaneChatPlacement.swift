import Foundation

/// `chat.placement {sessionId, placement}`: how a chat's place was chosen, kept as its acpmux
/// session tag `placement` (design/auto-chat-placement.md; Leo, 2026-11-18: "an auto mode as an
/// umbrella over remote/local/cloud itself. so it just goes."). `auto`: Auto picked where the chat
/// runs (this Mac, a joined machine or Cloud) and may move it while it runs; `pinned`: the person
/// pinned it where it runs (the chat row's pin), so Auto never moves it. The page reads the tag
/// back from the session list (webviews sessionList.ts). The app sets it on the daemon's socket
/// (`_acpmux/tag`, only this one tag), never through the pane's relay, which refuses `_acpmux/tag`,
/// and never as `session/new`'s `_meta.acpmux` (allow-listed).
public nonisolated struct AgentPaneChatPlacement: Equatable, Sendable {
    public static let method = "chat.placement"
    /// The session tag.
    public static let tag = "placement"
    /// The values the tag takes.
    public static let values: Set<String> = ["auto", "pinned"]

    public let sessionId: String
    public let placement: String

    /// Nil unless `params` are exactly `sessionId` (one non-empty id, at most 256 characters) and
    /// `placement` (`auto` or `pinned`).
    public init?(params: [String: Any]?) {
        guard let params, Set(params.keys) == ["sessionId", "placement"],
              let sessionId = params["sessionId"] as? String, !sessionId.isEmpty, sessionId.count <= 256,
              let placement = params["placement"] as? String, Self.values.contains(placement) else { return nil }
        self.sessionId = sessionId
        self.placement = placement
    }

    /// Whether this pane may mark `sessionId` so. `pinned` only stops Auto moving a chat, so any
    /// chat the page lists (the Home rows' pin) may be pinned. `auto` lets Auto move the chat, so
    /// only the pane's own chat, or the first chat of a new chat's pane (which has not learned its
    /// session yet when its first send's verdict comes back), may be marked Auto.
    func allowed(paneSession: String?) -> Bool {
        placement == "pinned" || paneSession == nil || paneSession == sessionId
    }
}

extension AgentPaneModel {
    /// Answers `chat.placement`: the tag on this Mac's acpmux, or a refusal the page shows nothing
    /// for (the chat keeps its place; only the row's word is missing).
    func respondToChatPlacement(_ request: AgentPaneChatPlacement) async -> [String: Any] {
        guard !remoteChat, request.allowed(paneSession: sessionId),
              let socketPath = transport.acpmuxSocket ?? transport.socketPath else {
            return Self.unsupported(AgentPaneChatPlacement.method)
        }
        do {
            try await AcpmuxStatusClient.tag(socketPath: socketPath, sessionId: request.sessionId,
                                             set: [AgentPaneChatPlacement.tag: request.placement], remove: [])
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "placement_failed", message: "placement_failed", details: nil, retryable: true,
                                          origin: "native")
        }
    }
}
