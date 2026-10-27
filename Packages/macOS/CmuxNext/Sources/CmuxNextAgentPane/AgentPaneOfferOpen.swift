/// `chat.offer.open {sessionId, sender?}`: the person clicked a session the chat shows, a
/// sub-session its agent started (at any depth, a transcript card or the Subagents summary), the
/// session that started this chat, or (`sender`) the chip of another agent's message to this chat,
/// any chat its daemon lists, this Mac's or a peer's (Leo, ask-7325396234: "I THINK I WANNA BE ABLE
/// TO CLICK ON THESE TO ACTUALLY GO TO THEM"). The tab that shows it already is shown and focused; else it opens as a tab
/// in the chat's side pane, or a split right of the chat (``AgentSidePanes``), focused because a
/// person asked for it. Allowed for a session `chat.sideChat` may open (``AgentPaneSideChat/holds``,
/// which covers a Cloud VM chat's children), the Cloud VM chat's parent (``RemoteAgentSessionLinks``),
/// of the chat's family (``AgentPaneHeaderHooks/isFamily``), or a message's sender: the page can
/// already show any session of its daemon in its own tab, so opening one beside it grants nothing
/// new. Never the chat itself, and not from a New Tab page; any other session is refused with
/// `chat.offer.refused`, which the page takes as final.
/// Nothing opens unless the person clicks. Kept off ``AgentPaneModel``, whose type is at its size limit.
enum AgentPaneOfferOpen {
    @MainActor static func respond(_ session: String, sender: Bool = false, workspace: Bool = false, focus: Bool = true, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.offer.open")
        }
        // Not "unsupported": the page must not fall back to opening it in this tab instead.
        let remoteParent = model.remoteChat && RemoteAgentSessionLinks.shared.parents[chat] == session
        guard session != chat, sender || AgentPaneSideChat.holds(session, chat: chat, in: model) || remoteParent || header.isFamily(session, chat) else {
            return AgentPaneReply.failure(code: "chat.offer.refused", message: "chat.offer.refused")
        }
        if workspace {
            return AgentPaneReply.success(["opened": header.openTab(session, .workspace)])
        }
        let shown = focus ? header.showSession(session) : (header.showSessionBackground?(session) ?? false)
        if !shown {
            if focus { header.openSide(chat, session) }
            else { header.openSideBackground?(chat, session) }
        }
        return AgentPaneReply.success()
    }
}
