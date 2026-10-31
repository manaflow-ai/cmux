/// `chat.asks.open {sessionId}`: the person went to another chat's ask from Needs you (its list, a
/// row's answer or side question, the Needs your input pill). The tab that shows that chat already
/// is shown and focused; else the chat opens on its right as a link does (`layout.linkPlacement`,
/// ``AgentPaneHeaderHooks/openRight``, ``RightColumnPlacement``): a new split there, else a split
/// below what is already on its right (a plain split's terminal included), else a tab in the right
/// column's lower pane, focused. Only when that opens nothing, it goes where ``AgentSidePanes``
/// puts New side chat and `/btw`. The chat on screen is never replaced: Needs you used to switch
/// this pane to the other chat in place (`chat.select`), and the person's own chat left its tab
/// (Leo, 2026-10-21, his coordinator); nor does it take a tab in this chat's pane (Leo, 2026-10-22:
/// "just do more on the side? ... or just do a split on the right").
///
/// Allowed for a chat on this pane's own acpmux on this Mac (``AgentPaneModel/pendingAsksSocket``,
/// whose chats Needs you lists, and a bare or `local/` id, ``AgentPanePendingAsks/localSession(_:)``):
/// the page's own client can already show any of them in place, so a tab of one grants nothing
/// more. Never the chat itself, a chat on another machine, or from a New Tab page; a refusal opens
/// nothing, and the page leaves the chat on screen as it is. Kept off ``AgentPaneModel``, whose
/// type is at its size limit.
enum AgentPaneAskOpen {
    @MainActor static func respond(_ session: String, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header,
              model.pendingAsksSocket != nil, let local = AgentPanePendingAsks.localSession(session),
              local != AgentPanePendingAsks.localSession(chat) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.asks.open")
        }
        let bare = String(local.dropFirst(AgentPanePendingAsks.localHost.count))
        if !header.showSession(bare), !header.openRight(bare) { header.openSide(chat, bare) }
        return AgentPaneReply.success()
    }
}
