/// `chat.offer.open {sessionId}`: the person clicked a session the chat shows, a sub-session its
/// agent started (at any depth, a transcript card or the Subagents summary) or the session that
/// started this chat. The tab that shows it already is shown and focused; else it opens as a tab
/// in the chat's side pane, or a split right of the chat (``AgentSidePanes``), focused because a
/// person asked for it. Allowed for a session in this pane's scope or of the chat's family
/// (``AgentPaneHeaderHooks/isFamily``), never the chat itself, and not from a New Tab page.
/// Nothing opens unless the person clicks. Kept off ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneOfferOpen {
    @MainActor static func respond(_ session: String, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, session != chat, let header = model.header,
              model.transport.sessions.contains(session) || header.isFamily(session, chat) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        if !header.showSession(session) { header.openSide(chat, session) }
        return AgentPaneReply.success()
    }
}
