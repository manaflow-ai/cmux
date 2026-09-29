/// Region of a pane that accepts a dropped tab.
public nonisolated enum PaneDropZone: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom
    /// Add the tab to the pane itself.
    case center

    /// Axis of the split a drop in this zone creates; nil for center.
    public var splitAxis: SplitAxis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }
}

/// Where a dragged tab would land.
public nonisolated enum DropTarget: Hashable, Sendable {
    /// Split `pane` at `zone`, or join it for `.center`.
    case pane(PaneID, PaneDropZone)
    /// Create a new column after `after` (nil = before the first column).
    case newColumn(screen: ScreenID, after: ColumnID?)
}
