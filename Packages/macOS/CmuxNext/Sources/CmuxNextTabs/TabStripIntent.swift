public import CoreGraphics
public import Foundation

/// What caused a close. `mouse` and `middleClick` enter Chrome's closing mode,
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
    case newTab(after: TabID?)
    case pin(TabID)
    case unpin(TabID)
    case rename(TabID)
    case duplicate(TabID)
    case moveToNewSplit(TabID, TabSplitDirection)
    case moveToNewColumn(TabID)
    /// A tab was dragged out of the strip. The App's drag session takes over
    /// pointer tracking; the strip keeps the slot collapsed until the model
    /// drops the tab or the App calls `TabStripView.restoreDetachedTab`.
    case dragBegan(TabDragStart)
}
