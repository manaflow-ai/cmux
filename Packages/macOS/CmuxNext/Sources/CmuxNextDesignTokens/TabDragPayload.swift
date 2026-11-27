public import CoreGraphics
public import Foundation

/// What the App's `TabDragSession` is dragging. Ids are the daemon's raw ids
/// so every feature module can conform without importing each other.
public nonisolated enum TabDragPayload: Hashable, Sendable {
    case tab(id: String, sourceStripID: UUID)
    /// A whole tab group. `width` is the group's width in its source strip,
    /// so a destination strip can open a gap of the same size.
    case tabGroup(id: String, tabIDs: [String], sourceStripID: UUID, width: CGFloat)
}

/// Edge of a pane for a new split.
public nonisolated enum TabDropEdge: Hashable, Sendable {
    case left, right, top, bottom
}

/// Where a drop would land. The App maps each kind to one atomic daemon
/// command (move-tab, tab-to-new-split, tab-to-new-column, ...).
public nonisolated enum TabDropKind: Hashable, Sendable {
    /// Into a tab strip at `index` (final index in the strip's display
    /// order), joining `groupID` when non-nil (tab payloads only).
    case strip(stripID: UUID, index: Int, groupID: String?)
    case newSplit(paneID: String, edge: TabDropEdge)
    case newColumn(screenID: String, afterColumnID: String?)
    /// A new top or bottom dock on `screenID` (`edge` "top" or "bottom").
    case newDock(screenID: String, edge: String)
    case newWorkspace(groupID: String?, index: Int)
    case workspace(id: String)
}
