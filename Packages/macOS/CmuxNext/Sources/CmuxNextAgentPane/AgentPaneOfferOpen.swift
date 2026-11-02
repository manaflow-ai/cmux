/// `chat.offer.open {sessionId, sender?}`: the person clicked a session the chat shows, a
/// sub-session its agent started (at any depth, a transcript card or the Subagents summary), the
/// session that started this chat, or (`sender`) the chip of another agent's message to this chat,
/// any chat its daemon lists, this Mac's or a peer's (Leo, ask-7325396234: "I THINK I WANNA BE ABLE
/// TO CLICK ON THESE TO ACTUALLY GO TO THEM"). A tab that shows it already beside the chat (in its pane or
/// its right column) is shown and focused; else it opens on the chat's right where
/// ``RightColumnPlacement`` says (``AgentSidePanes``), focused because a person asked for it. A tab
/// of it in another workspace is never jumped to (Leo, ask-c7a066ffa2: "We can just open them up in
/// the right pane. ... Why are you sending me to a new workspace? Don't do that."). Allowed for a session `chat.sideChat` may open (``AgentPaneSideChat/holds``,
/// which covers a Cloud VM chat's children), the Cloud VM chat's parent (``RemoteAgentSessionLinks``),
/// of the chat's family (``AgentPaneHeaderHooks/isFamily``), or a message's sender: the page can
/// already show any session of its daemon in its own tab, so opening one beside it grants nothing
/// new. Never the chat itself, and not from a New Tab page; any other session is refused with
/// `chat.offer.refused`, which the page takes as final.
/// Nothing opens unless the person clicks. Kept off ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneOfferOpen {
    @MainActor static func respond(_ session: String, sender: Bool = false, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        // Not "unsupported": the page must not fall back to opening it in this tab instead.
        // A hostless route reads the hostless map its wire noted the daemon's links in.
        let remoteParent = model.remoteChat
            && RemoteAgentSessionLinks.shared.parent(of: chat, host: model.transport.remoteHostID) == session
        guard session != chat, sender || AgentPaneSideChat.holds(session, chat: chat, in: model) || remoteParent || header.isFamily(session, chat) else {
            return AgentPaneReply.failure(code: "chat.offer.refused", message: "chat.offer.refused")
        }
        if !header.showSession(session) { header.openSide(chat, session) }
        return AgentPaneReply.success()
    }
}
