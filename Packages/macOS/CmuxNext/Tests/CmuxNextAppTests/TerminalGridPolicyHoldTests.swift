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
        #expect(!policy.previewsViewGrid, "the view's preview reflows the final grid back to the frame's size")
        for columns in stride(from: 159, through: 81, by: -1) { #expect(policy.viewSized(grid(columns, 40), holding: true) == nil) }
        #expect(policy.viewSized(grid(80, 40), holding: true) == nil)
        #expect(policy.previewsViewGrid)
        #expect(policy.releaseHeld() == nil, "the landing at the final grid reported again")
        #expect(policy.final == nil)
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
