import Testing
@testable import CmuxTerminal

/// The tmux-assigned grid outranks the view's points on a mirror pane, in
/// both directions. Short: the divider plan can legitimately hand a pane
/// fewer points than its assigned cells need (a starved sibling's chrome
/// floor is paid out of this pane's rail share), and a grid derived from
/// the shorter view wraps text differently than the tmux pane it mirrors.
/// Long: a wider grid never sets wrap flags where tmux wrapped (unwrapped
/// reads split one tmux line into many) and a taller grid keeps stale rows
/// tmux never repaints. The pin hands ghostty exactly the assigned grid's
/// pixels; the view clips or letterboxes the difference.
struct AssignedGridPinGeometryTests {
    /// The live short case: 1351px of view for 86 assigned columns at 16px
    /// cells — the pane rendered 83-84 and its wraps diverged from tmux.
    @Test func pinRaisesAShortAxisToAssignedCells() {
        let pinned = TerminalSurface.assignedGridPinnedSize(
            width: 1351, height: 748 + 14,
            assignedColumns: 86, assignedRows: 22,
            cellWidthPx: 16, cellHeightPx: 34,
            padWidthPx: 7, padHeightPx: 14
        )
        #expect(pinned.width == UInt32(86 * 16 + 7))
        #expect(pinned.height == UInt32(22 * 34 + 14))
    }

    /// The live long case: the one-column starved pane's 31pt floored view
    /// derived a ~3-column grid, so "END 001x022" never wrapped where tmux
    /// wrapped it and the unwrapped read gained seven lines. The pin hands
    /// ghostty exactly one column.
    @Test func pinLowersASurplusAxisToAssignedCells() {
        let pinned = TerminalSurface.assignedGridPinnedSize(
            width: 56, height: 762,
            assignedColumns: 1, assignedRows: 22,
            cellWidthPx: 16, cellHeightPx: 34,
            padWidthPx: 7, padHeightPx: 14
        )
        #expect(pinned.width == UInt32(1 * 16 + 7))
        #expect(pinned.height == UInt32(22 * 34 + 14))
    }

    /// A pre-font surface reports zero cell metrics; the pin must be inert
    /// rather than manufacture a size from nothing.
    @Test func pinIsInertWithoutCellMetrics() {
        let pinned = TerminalSurface.assignedGridPinnedSize(
            width: 640, height: 480,
            assignedColumns: 86, assignedRows: 22,
            cellWidthPx: 0, cellHeightPx: 34,
            padWidthPx: 0, padHeightPx: 0
        )
        #expect(pinned.width == 640)
        #expect(pinned.height == 480)
    }

    /// A degenerate assignment (a pane mid-teardown can report zero span)
    /// is ignored the same way.
    @Test func pinIsInertForADegenerateAssignment() {
        let pinned = TerminalSurface.assignedGridPinnedSize(
            width: 640, height: 480,
            assignedColumns: 0, assignedRows: 22,
            cellWidthPx: 16, cellHeightPx: 34,
            padWidthPx: 7, padHeightPx: 14
        )
        #expect(pinned.width == 640)
        #expect(pinned.height == 480)
    }
}
