/// Where a person's new tab goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app). The chat dock is
/// the left dock column with the agent chat role: tools opened from it are
/// tabs in the scrolling strip. It shows its tab bar like every pane
/// (cx-v4dmy).
public nonisolated enum ChatColumnPlacement: Equatable, Sendable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in this pane of the scrolling strip.
    case tab(in: PaneID)
    /// The chat is alone on its screen: it moves into a new left dock with
    /// the agent chat role, and the new tab stays in its pane.
    case dockChat
    /// The chat dock is a pinned column alone on its screen (Home with
    /// nothing beside it, `pinned-dock-alone-v1`): the new tab opens in a new
    /// column right of it, whether or not the dock takes dragged tabs.
    case besideDock

    /// `columns` are the screen's, in strip order; `recent` orders panes by
    /// last focus, newest first; `isLoneChat` says whether a column is one
    /// pane holding one agent chat. Only the role makes a chat dock: chats
    /// in a plain dock or beside other columns are normal panes. A `zoomed`
    /// screen shows only its zoomed pane, so nothing docks or moves. The
    /// daemon keeps a dock without a scrolling column only when it is pinned
    /// (Home's dock alone); its new tabs open in a new column beside it.
    public nonisolated static func resolve(from pane: PaneID, columns: [LayoutColumn], recent: [PaneID] = [],
                                              zoomed: Bool = false, isLoneChat: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        guard !zoomed, let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return .here }
        let column = columns[index]
        let strip = columns.filter { $0.dock == nil }
        if column.dock?.role == .agentChat {
            guard let target = strip.first else { return column.dock?.isPinned == true ? .besideDock : .here }
            return .tab(in: recent.first { id in strip.contains { $0.root.contains(id) } } ?? target.root.panes[0])
        }
        guard column.dock == nil, strip.count == 1, !columns.contains(where: { $0.dock?.role == .agentChat }),
              isLoneChat(column) else { return .here }
        return .dockChat
    }

    /// `screen`'s columns in strip order. A screen stored as one split tree
    /// is one implicit column.
    public nonisolated static func columns(of screen: LayoutScreen, containing pane: PaneID) -> [LayoutColumn] {
        screen.layout.columns.isEmpty
            ? screen.column(containing: pane).map { [$0] } ?? [] : screen.layout.columns
    }
}

/// Where a new agent chat opens (lawrence-call-1006 D): the agent chat is a
/// docked column on the left (the dock column with the agent chat role),
/// never a tab in the strip.
public nonisolated enum NewChatPlacement: Equatable, Sendable {
    /// A tab in the pane it was opened from.
    case here
    /// A tab in the chat dock's pane (or, beside Home's pinned chat dock,
    /// in the first scrolling pane).
    case dock(PaneID)
    /// A new left chat dock, made from the chat once it exists.
    case newDock
    /// A new column right of the chat dock: Home's pinned dock alone on its screen
    /// (`pinned-dock-alone-v1`) takes no chat and has no scrolling pane beside it.
    case besideDock

    /// `columns` are the pane's screen's; `isLoneChat` says the pane's column
    /// is one pane holding one agent chat, the only scrolling column. A lone
    /// chat docks when the first tool opens (``ChatColumnPlacement``), so a
    /// second chat joins its pane.
    public nonisolated static func resolve(from pane: PaneID, columns: [LayoutColumn], isLoneChat: Bool) -> NewChatPlacement {
        guard columns.contains(where: { $0.root.contains(pane) }) else { return .here }
        if let dock = columns.first(where: { $0.dock?.role == .agentChat }) {
            if dock.dock?.isPinned != true { return .dock(dock.root.panes[0]) }
            // `pinned-dock-v1`: a pinned chat dock (Home's) takes no new chat, even while it takes
            // dragged tabs (`allow_tabs`). It opens where it was asked for, or in the first
            // scrolling pane when that was the dock itself.
            guard dock.root.contains(pane) else { return .here }
            return columns.first(where: { $0.dock == nil }).map { NewChatPlacement.dock($0.root.panes[0]) } ?? .besideDock
        }
        return isLoneChat ? .here : .newDock
    }
}
