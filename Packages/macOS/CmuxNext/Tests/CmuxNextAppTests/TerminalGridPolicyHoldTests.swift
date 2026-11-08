import CmuxNextTerminalGeometry
import Testing

/// A terminal on a layout spring (Cmd-Shift-Enter zoom) holds its grid reports and reports the
/// last grid once when the spring lands (``TerminalGridPolicy/releaseHeld()``).
@Suite struct TerminalGridPolicyHoldTests {
    private func grid(_ columns: Int, _ rows: Int) -> TerminalGridSize { TerminalGridSize(columns: columns, rows: rows) }

    @Test func heldSizesReportNothingUntilReleaseThenTheLastOnce() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        #expect(policy.viewSized(grid(80, 24)) == grid(80, 24))
        for columns in 81...160 { #expect(policy.viewSized(grid(columns, 24 + columns / 10), holding: true) == nil) }
        #expect(policy.desired == grid(160, 40))
        #expect(policy.releaseHeld() == grid(160, 40))
        #expect(policy.releaseHeld() == nil, "a second release reported again")
    }

    @Test func aHoldThatEndsBackAtTheReportedGridReportsNothing() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        _ = policy.viewSized(grid(80, 24))
        _ = policy.viewSized(grid(100, 30), holding: true)
        _ = policy.viewSized(grid(80, 24), holding: true)
        #expect(policy.releaseHeld() == nil)
    }

    /// A split or close reports the final grid at its start; every frame's size is held, and the landing at
    /// the final grid reports nothing more (one PTY resize, at the start).
    @Test func aFinalGridReportsAtTheStartAndTheLandingAtItReportsNothing() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        _ = policy.viewSized(grid(160, 40))
        #expect(policy.finalSized(grid(80, 40)) == grid(80, 40))
        #expect(!policy.previewsViewGrid(followingPane: false), "the view's preview reflows the final grid back to the frame's size")
        for columns in stride(from: 159, through: 81, by: -1) { #expect(policy.viewSized(grid(columns, 40), holding: true) == nil) }
        #expect(policy.viewSized(grid(80, 40), holding: true) == nil)
        #expect(policy.previewsViewGrid(followingPane: false))
        #expect(policy.releaseHeld() == nil, "the landing at the final grid reported again")
        #expect(policy.final == nil)
    }

    /// cmux-ad m14: a view that takes its pane's size in every frame of a key resize (`motion.frameOwner.terminals` on)
    /// keeps its preview while the final grid does not fit it, so each frame draws the grid its size fits; the final grid
    /// still goes once, at the start, and the landing at it reports nothing more.
    @Test func aViewThatFollowsItsPaneKeepsItsPreviewWhileTheFinalGridDoesNotFit() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        _ = policy.viewSized(grid(80, 24))
        #expect(policy.finalSized(grid(80, 40)) == grid(80, 40))
        for rows in 25...39 {
            #expect(policy.viewSized(grid(80, rows), holding: true) == nil)
            #expect(policy.previewsViewGrid(followingPane: true), "a following view at 80x\(rows) lost its preview")
            #expect(!policy.previewsViewGrid(followingPane: false))
        }
        #expect(policy.viewSized(grid(80, 40), holding: true) == nil)
        #expect(policy.releaseHeld() == nil, "the landing at the final grid reported again")
        #expect(policy.previewsViewGrid(followingPane: true) && policy.previewsViewGrid(followingPane: false))
    }

    /// A burst retargets the final grid; a landing off it (a rounding miss) still reports the landed grid.
    @Test func aNewerFinalGridReplacesTheOlderAndALandingOffItReportsTheLandedGrid() {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        _ = policy.viewSized(grid(160, 40))
        #expect(policy.finalSized(grid(80, 40)) == grid(80, 40))
        #expect(policy.finalSized(grid(80, 40)) == nil, "the same final grid reported twice")
        #expect(policy.finalSized(grid(53, 40)) == grid(53, 40))
        _ = policy.viewSized(grid(54, 40), holding: true)
        #expect(policy.releaseHeld() == grid(54, 40))
    }

    @Test func aFollowerReportsNoFinalGrid() {
        var policy = TerminalGridPolicy(ownsGeometry: false)
        #expect(policy.finalSized(grid(80, 40)) == nil)
    }

    @Test func aFollowerHoldsNothing() {
        var policy = TerminalGridPolicy(ownsGeometry: false)
        _ = policy.viewSized(grid(100, 30), holding: true)
        #expect(policy.releaseHeld() == nil)
    }
}
