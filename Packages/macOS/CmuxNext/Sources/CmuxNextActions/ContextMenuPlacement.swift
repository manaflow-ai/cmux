/// Semantic group of a right-click menu row. Menus list groups in this
/// order with a separator between them, so a new action lands in the right
/// area of every menu by naming its group.
public nonisolated enum MenuGroup: Int, CaseIterable, Sendable, Hashable, Comparable {
    /// Copy, paste, select all, use selection.
    case edit
    /// Back, forward, reload, open a link or a row.
    case navigate
    /// New, duplicate, split, open a kind of tab.
    case create
    /// Reopen in another engine or profile.
    case reopen
    /// Rename, color, icon, pin, read state, theme, status, defaults.
    case identity
    /// Group membership, saved groups, collapse.
    case organize
    /// Move or reorder to another place.
    case move
    /// Size, zoom, equalize, docked.
    case layout
    /// Reconnect, disconnect, hibernate, swap a session.
    case connection
    /// Resources, IDs, links, page info, developer tools, screenshots.
    case inspect
    /// Show or hide chrome (sidebar, bookmarks bar).
    case view
    /// Clear or reset content.
    case reset
    /// Close, delete, forget, ungroup.
    case close

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a placement renders.
public nonisolated enum MenuPlacementStyle: Sendable, Hashable {
    /// One menu item.
    case item
    /// A submenu with one item per value of the action's first enumeration
    /// argument (``ContextMenuEntry/choices(_:)``).
    case choices
    /// A submenu titled by the action whose children are the placements in
    /// the same context that name this action as their `parent`.
    case submenu
}

/// One row of one right-click menu, declared by the action.
public nonisolated struct ContextMenuPlacement: Sendable, Hashable {
    public var context: ActionMenuContext
    public var group: MenuGroup
    /// Order inside the group. Ranks in different hundreds are separate
    /// sections of the group (a separator between them).
    public var rank: Int
    public var style: MenuPlacementStyle
    /// The submenu anchor this row belongs to, if any.
    public var parent: ActionID?
    /// The titled submenu the row lives in (``MenuFolder``); nil keeps it
    /// at the top level.
    public var folder: MenuFolder?

    public init(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int = 0,
                style: MenuPlacementStyle = .item, parent: ActionID? = nil, folder: MenuFolder? = nil) {
        self.context = context
        self.group = group
        self.rank = rank
        self.style = style
        self.parent = parent
        self.folder = folder
    }
}
