/// `chat.offer.open {sessionId}`: the person clicked a session the chat offers to open (a
/// sub-session its agent started, at any depth, or the session that started this chat). It opens
/// as a tab beside this chat through the app's shared session-tab opener, reusing a tab that shows
/// it already, and takes focus because a person asked for it. Allowed for a session in this pane's
/// scope or of the chat's family (``AgentPaneHeaderHooks/isFamily``), never the chat itself, and
/// not from a New Tab page. Kept off ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneOfferOpen {
    static func respond(_ session: String, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, session != chat, let header = model.header,
              model.transport.sessions.contains(session) || header.isFamily(chat, session),
              header.openSession(chat, session) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        return AgentPaneReply.success()
    }
}
