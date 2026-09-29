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
}
