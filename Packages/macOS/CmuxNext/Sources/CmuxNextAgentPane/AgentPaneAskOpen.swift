/// `chat.asks.open {sessionId, where?}`: the person went to another chat's ask from Needs you (its
/// list, a row's answer or side question, the Needs your input pill, an expanded row's places).
///
/// `right` (no `where`, the default): a tab that shows that chat already beside this one (its pane
/// or right column, never another workspace) is shown and focused; else the chat opens on its right
/// as a link does (`layout.linkPlacement`, ``AgentPaneHeaderHooks/openRight``,
/// ``RightColumnPlacement``): a new split there, else a split below what is already on its right (a
/// plain split's terminal included), else a tab in the right column's lower pane, focused. Only when
/// that opens nothing, it goes where ``AgentSidePanes`` puts New side chat and `/btw`. The chat on
/// screen is never replaced: Needs you used to switch this pane to the other chat in place
/// (`chat.select`), and the person's own chat left its tab (Leo, 2026-10-21, his coordinator); nor
/// does it take a tab in this chat's pane (Leo, 2026-10-22: "just do more on the side? ... or just
/// do a split on the right").
///
/// The expanded row's other places, which the person picks by name (Leo, 2026-10-21: "MAYBE JUMP
/// TO THAT WORKSPACE... OR OPEN NEW WORKSPACE... OR OPEN ON RIGHT"): `workspace` switches to the tab
/// that shows the chat in whatever workspace or window (``AgentPaneHeaderHooks/jumpToSession``),
/// and opens it on the right as above when no tab shows it; `newWorkspace` opens it in a new
/// workspace (``AgentForkDestination/workspace``), else on the right.
///
/// Allowed for a chat on this pane's own acpmux on this Mac (``AgentPaneModel/pendingAsksSocket``,
/// whose chats Needs you lists, and a bare or `local/` id, ``AgentPanePendingAsks/localSession(_:)``):
/// the page's own client can already show any of them in place, so a tab of one grants nothing
/// more. Never the chat itself, a chat on another machine, or from a New Tab page; a refusal opens
/// nothing, and the page leaves the chat on screen as it is. Kept off ``AgentPaneModel``, whose
/// type is at its size limit.
enum AgentPaneAskOpen {
    @MainActor static func respond(_ session: String, at place: AgentPaneAskPlace = .right, in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header,
              model.pendingAsksSocket != nil, let local = AgentPanePendingAsks.localSession(session),
              local != AgentPanePendingAsks.localSession(chat) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.asks.open")
        }
        let bare = String(local.dropFirst(AgentPanePendingAsks.localHost.count))
        switch place {
        case .workspace where header.jumpToSession(bare): return AgentPaneReply.success()
        case .newWorkspace where header.openTab(bare, .workspace): return AgentPaneReply.success()
        case .right, .workspace, .newWorkspace: break
        }
        if !header.showSession(bare), !header.openRight(bare) { header.openSide(chat, bare) }
        return AgentPaneReply.success()
    }
}

/// Where `chat.asks.open` opens the chat: its `where` (``AgentPaneAskOpen``).
public nonisolated enum AgentPaneAskPlace: String, Equatable, Sendable {
    case right
    case workspace
    case newWorkspace

    /// `where` absent is `right`; any value but the three names is nil (refused).
    init?(_ value: Any?) {
        guard let value else { self = .right; return }
        guard let name = value as? String, let place = Self(rawValue: name) else { return nil }
        self = place
    }
}
