import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
import Testing

/// Review of #28044 at c15e0d89: two links opened before either one's move landed both read a
/// one-pane right column and both split below it, leaving three panes on the right. A lower split
/// under way is reserved (RightColumn.reserveBelow): until it lands, the column reads as full, so the
/// second open is a tab, in the right pane that holds the moving tab until then.
@MainActor @Suite(.serialized) struct RightColumnPendingSplitTests {
    private let diff = LayoutPaneID("pending-test-diff")

    private func decide(_ column: [LayoutPaneID]) -> RightColumnPlacement.Decision<LayoutPaneID> {
        RightColumnPlacement.decide(sourceWidth: 1400, column: RightColumn.withPendingSplits(column), width: { _ in 700 })
    }

    @Test func aSecondOpenWhileALowerSplitIsUnderWayIsATab() throws {
        #expect(decide([diff]) == .splitBelow(diff))
        let release = RightColumn.reserveBelow(diff)
        let second = decide([diff])
        guard case .tab(let pane?) = second else { Issue.record("the second open split again: \(second)"); release(); return }
        #expect(RightColumn.realPane(pane) == diff, "the second open's tab goes to the right pane that holds the moving tab")
        release()
        release()
        #expect(decide([diff]) == .splitBelow(diff), "a landed or failed split frees the column")
    }

    @Test func overlappingReservationsHoldUntilTheLastEnds() {
        let first = RightColumn.reserveBelow(diff), second = RightColumn.reserveBelow(diff)
        first()
        #expect(RightColumn.withPendingSplits([diff]).count == 2, "one split still under way")
        second()
        #expect(RightColumn.withPendingSplits([diff]) == [diff])
        #expect(RightColumn.withPendingSplits([diff, LayoutPaneID("lower")]).count == 2, "a full column is left as it is")
    }
}
