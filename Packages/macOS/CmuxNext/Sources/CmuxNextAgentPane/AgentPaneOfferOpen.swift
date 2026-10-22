/// `chat.offer.open {sessionId}`: the person clicked a session the chat shows, a sub-session its
/// agent started (at any depth, a transcript card or the Subagents summary) or the session that
/// started this chat. The tab that shows it already is shown and focused; else it opens as a tab
/// in the chat's side pane, or a split right of the chat (``AgentSidePanes``), focused because a
/// person asked for it. Allowed for a session `chat.sideChat` may open (``AgentPaneSideChat/holds``,
/// which covers a Cloud VM chat's children), the Cloud VM chat's parent (``RemoteAgentSessionLinks``),
/// or of the chat's family (``AgentPaneHeaderHooks/isFamily``),
/// never the chat itself, and not from a New Tab page; any other session is refused with
/// `chat.offer.refused`, which the page takes as final.
/// Nothing opens unless the person clicks. Kept off ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneOfferOpen {
    @MainActor static func respond(_ session: String, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        // Not "unsupported": the page must not fall back to opening it in this tab instead.
        let remoteParent = model.remoteChat && RemoteAgentSessionLinks.shared.parents[chat] == session
        guard session != chat, AgentPaneSideChat.holds(session, chat: chat, in: model) || remoteParent || header.isFamily(session, chat) else {
            return AgentPaneReply.failure(code: "chat.offer.refused", message: "chat.offer.refused")
        }
        if !header.showSession(session) { header.openSide(chat, session) }
        return AgentPaneReply.success()
    }
}
