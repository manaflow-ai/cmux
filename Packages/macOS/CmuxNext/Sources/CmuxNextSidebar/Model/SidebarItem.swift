public import CmuxNextDesign

/// One sidebar destination (SIDEBAR-SELECTION-ONE-MODEL): a top-section item
/// (Home, the App Store, any top item), a collapsed group (one stop), or a
/// workspace row. The window's one sidebar selection is a `SidebarItem`;
/// stepping, numbering, click, keyboard, automation and accessibility all
/// read and write that one value. Hover, focus ring and drop indication are
/// separate visual states.
public nonisolated enum SidebarItem: Hashable, Sendable {
    case topItem(LayoutItemID)
    case group(GroupID)
    case workspace(WorkspaceID)
}

/// The window's sidebar destinations in shown order: the visible top-section
/// items, then the rows the list draws from `SidebarSection.nodes` (the one
/// shown order, incl. groups among loose workspaces). An expanded group is its
/// rows; a collapsed group is one stop.
public nonisolated struct SidebarItemOrder: Hashable, Sendable {
    public let topItems: [SidebarItem]
    public let rows: [SidebarItem]
    /// The stop that stands for a workspace without its own row (a member of a collapsed group).
    public let stops: [WorkspaceID: SidebarItem]

    public init(topItems: [SidebarItem], rows: [SidebarItem], stops: [WorkspaceID: SidebarItem] = [:]) {
        self.topItems = topItems
        self.rows = rows
        self.stops = stops
    }

    public var items: [SidebarItem] { topItems + rows }

    public func items(_ scope: SidebarNavigationSettings.Scope) -> [SidebarItem] {
        scope == .allItems ? items : rows
    }

    /// The stop in this order that `item` is at (a workspace in a collapsed group: the group).
    public func stop(for item: SidebarItem?) -> SidebarItem? {
        nil // RED stub
    }

    /// The item Cmd-`number` selects: 1…8 count in order; 9 is the last
    /// (`last`) or the ninth (`ninth`). Past the end: the last with `last`,
    /// nothing with `ninth`. Nil below 1 or for an empty order.
    public func pick(_ number: Int, _ settings: SidebarNavigationSettings) -> SidebarItem? {
        nil // RED stub
    }

    /// The item `offset` steps from `selected` (Cmd-Ctrl-] is +1). From an
    /// item outside the walked list (or none), +1 starts at the first and -1
    /// at the last. Past an end: wraps, or nil when wrapping is off.
    public func step(from selected: SidebarItem?, by offset: Int, _ settings: SidebarNavigationSettings) -> SidebarItem? {
        nil // RED stub
    }
}
