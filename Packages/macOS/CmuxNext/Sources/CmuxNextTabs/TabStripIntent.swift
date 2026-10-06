public import CoreGraphics
public import Foundation

/// What caused a close. `mouse` and `middleClick` enter closing mode,
/// which keeps tab widths frozen until the pointer leaves the strip.
public enum TabCloseSource: Hashable, Sendable {
    case mouse
    case middleClick
    case keyboard
    case contextMenu
    case accessibility

    var entersClosingMode: Bool { self == .mouse || self == .middleClick }
}

public enum TabSplitDirection: Hashable, Sendable {
    case right
    case down
}

/// Everything the strip asks the App to do. The strip never mutates layout
/// or daemon state itself; the App applies an intent and updates the model.
/// Indices are positions in `TabStripModel.orderedTabs` (pinned first).
public enum TabStripIntent: Equatable, Sendable {
    case select(TabID)
    case close(TabID, source: TabCloseSource)
    case closeOthers(keeping: TabID)
    case closeToRight(of: TabID)
    /// Drag reorder inside one strip. `to` is the final index of the tab.
    case reorder(TabID, from: Int, to: Int)
    /// `after` is nil for the new-tab button and empty-space double-click (append).
    /// `opensWorkspace` is a one-shot Option-click override for terminal tabs.
    case newTab(after: TabID?, opensWorkspace: Bool = false)
    case pin(TabID)
    case unpin(TabID)
    case rename(TabID)
    /// The inline rename editor (`TabStripView.beginInlineRename`) committed
    /// `name` (trimmed; empty clears the custom name).
    case renameCommitted(TabID, name: String)
    case duplicate(TabID)
    case moveToNewSplit(TabID, TabSplitDirection)
    case moveToNewColumn(TabID)
    /// A trailing group button (`TabStripModel.trailingButtons`) was clicked.
    case trailingButton(String)
    /// A tab was dragged out of the strip. The App's drag session takes over
    /// pointer tracking; the strip keeps the slot collapsed until the model
    /// drops the tab or the App calls `TabStripView.restoreDetachedTab`.
    case dragBegan(TabDragStart)

    // MARK: Groups

    /// Chip click. Collapsing a group that holds the selection moves the
    /// selection out of it first (the reducer shows how).
    case toggleGroupCollapsed(TabGroupID)
    /// Chip drag inside the strip. `to` is the final index of the group's
    /// first tab in `orderedTabs`.
    case moveGroup(TabGroupID, to: Int)
    /// A tab joined a group. `index` is the tab's final index in
    /// `orderedTabs`, or nil to append it to the group.
    case addToGroup(TabID, TabGroupID, index: Int?)
    /// A tab left its group. `index` is its final index, or nil to place it
    /// right after the group ("Remove from group").
    case removeFromGroup(TabID, index: Int?)
    /// A group chip was dragged out of the strip. Same contract as
    /// `dragBegan`: the App must end it with a model change or
    /// `TabStripView.restoreDetachedGroup`.
    case groupDragBegan(TabGroupDragStart)
    /// A group action from the editor bubble (or any App entrypoint).
    case group(TabGroupCommand)
    /// Creates `group` from `tabs` (pinned tabs are skipped). Never sent by
    /// the strip; the App's "Add tab to new group" action and the demo use it
    /// with the local reducer.
    case createGroup(TabGroupItem, tabs: [TabID])
}
