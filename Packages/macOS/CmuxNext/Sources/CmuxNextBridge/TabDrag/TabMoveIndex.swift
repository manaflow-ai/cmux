/// Index conversions for the daemon's `move-tab`.
public nonisolated enum TabMoveIndex {
    /// The wire index for moving a tab to `finalIndex` (its position after
    /// the move). `move-tab` takes insertion coordinates in the pre-move
    /// list: for a same-pane move the daemon removes the tab first and
    /// subtracts one from an index past it (cmux-tui spec "move-tab").
    /// `currentIndex` is the tab's index when it is already in the
    /// destination pane, else nil (cross-pane moves use the final index).
    public static func wireIndex(finalIndex: Int, currentIndex: Int?) -> Int {
        guard let currentIndex, finalIndex > currentIndex else { return max(0, finalIndex) }
        return finalIndex + 1
    }

    /// The final index in the pane's own (daemon) order for a strip drop
    /// that puts `moving` at `displayIndex` of the strip's display order.
    /// The strip shows pinned tabs first, group members together, closing
    /// tabs hidden and app-local tabs last, so a display index is not a
    /// pane index. The tab goes right before the pane tab that follows it
    /// in the new display order, else last.
    public static func paneFinalIndex(display: [String], moving: String, displayIndex: Int, pane: [String]) -> Int {
        displayIndex
    }
}
