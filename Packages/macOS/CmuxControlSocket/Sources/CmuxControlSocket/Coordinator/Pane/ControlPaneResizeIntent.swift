/// One validated `pane.resize` operation with its coordinate system encoded in
/// the case, so providers never reinterpret points, cells, percentages, or tmux
/// adjustment flags after the coordinator boundary.
public enum ControlPaneResizeIntent: Sendable, Equatable {
    /// Grow a pane through the named adjacent border by native layout points.
    case borderRelative(direction: String, amountPoints: Int)
    /// Set a pane's outer native extent in layout points.
    case outerAbsolute(axis: String, targetPoints: Double)
    /// Preserve native tmux directional-adjustment semantics and exact cells.
    case tmuxRelative(direction: String, amountCells: Int, fallbackPoints: Int?)
    /// Preserve a native tmux absolute size in terminal cells.
    case tmuxAbsoluteCells(axis: String, targetCells: Int, fallbackPoints: Double?)
    /// Preserve a native tmux absolute size as a window percentage.
    case tmuxAbsolutePercentage(axis: String, percentage: Int, fallbackPoints: Double?)
}
