/// `chat.offer.open {sessionId}`: the person clicked a session the chat shows, a sub-session its
/// agent started (at any depth, a transcript card or the Subagents summary) or the session that
/// started this chat. The tab that shows it already is shown and focused; else it opens as a tab
/// in the chat's side pane, or a split right of the chat (``AgentSidePanes``), focused because a
/// person asked for it. Allowed for a session in this pane's scope or of the chat's family
/// (``isFamily``), never the chat itself, and not from a New Tab page. Nothing opens unless the
/// person clicks. Kept off ``AgentPaneModel``, whose type is at its size limit.
public enum AgentPaneOfferOpen {
    /// Whether `session` is of chat `chat`'s family: a sub-session it started at any depth, or the
    /// session that started it (acpmux `startedBy`). Set at launch by the turn-state watch, which
    /// mirrors those links; nil (none is) until then.
    @MainActor public static var isFamily: (@MainActor (_ session: String, _ chat: String) -> Bool)?

    @MainActor static func respond(_ session: String, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, session != chat, let header = model.header,
              model.transport.sessions.contains(session) || isFamily?(session, chat) == true else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        if !header.showSession(session) { header.openSide(chat, session) }
        return AgentPaneReply.success()
    }
}
