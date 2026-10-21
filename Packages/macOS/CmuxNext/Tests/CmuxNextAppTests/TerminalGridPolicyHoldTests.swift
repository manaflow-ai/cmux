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

    @Test func aFollowerHoldsNothing() {
        var policy = TerminalGridPolicy(ownsGeometry: false)
        _ = policy.viewSized(grid(100, 30), holding: true)
        #expect(policy.releaseHeld() == nil)
    }
}
