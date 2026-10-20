public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextTabs

// Tab drop rules taken from bonsplit, classic cmux's split view (#22287).

nonisolated extension TabDragPayload {
    /// Where a drop on the body of a pane whose strip shows `tabs` (display
    /// order) leaves the dragged tabs when they are in it: their own slot
    /// and, for a single tab, its own tab group, so the drop changes nothing
    /// (`TabDragContext.isOwnPlace`), as in bonsplit. Nil when they are not there.
    public func ownPlace(in tabs: [CmuxNextTabs.TabItem]) -> (index: Int, group: String?)? {
        let first: String? = switch self {
        case .tab(let id, _): id
        case .tabGroup(_, let ids, _, _): ids.first
        }
        guard let index = tabs.firstIndex(where: { $0.id.rawValue == first }) else { return nil }
        guard case .tab = self else { return (index, nil) }
        return (index, tabs[index].groupID?.rawValue)
    }
}

/// What a split of a pane with its only tab leaves in that pane
/// (`TabMoves.respawn`). bonsplit splits it and leaves a placeholder that
/// classic cmux fills with a terminal.
public nonisolated enum SplitLeftover: Hashable, Sendable {
    /// A fresh tab of the same kind (a browser falls back to a terminal).
    case sameKind
    /// A fresh terminal.
    case terminal
    /// Nothing: the split is refused. Conversation tabs (Home and agent
    /// chats) show one conversation or session, which has no fresh copy.
    case nothing

    public init(kind: CmuxNextDaemon.TabKind) {
        switch kind {
        case .pty, .browser: self = .sameKind
        case .conversation: self = .nothing
        case .remoteTerminal, .other: self = .terminal
        }
    }
}
