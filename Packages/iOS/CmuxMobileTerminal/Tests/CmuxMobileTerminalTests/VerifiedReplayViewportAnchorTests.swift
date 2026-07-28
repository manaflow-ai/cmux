import Testing

@testable import CmuxMobileTerminal

@Suite("Verified replay viewport anchor")
struct VerifiedReplayViewportAnchorTests {
    @Test("an at-bottom viewport follows replay output naturally")
    func atBottomDoesNotRestore() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 0, totalRows: 100)

        #expect(anchor.targetTopRow(postReplayTotalRows: 120, postReplayVisibleRows: 20) == nil)
    }

    @Test("an unchanged row space restores the prior top row")
    func plainRestore() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 30, totalRows: 100)

        #expect(anchor.targetTopRow(postReplayTotalRows: 100, postReplayVisibleRows: 20) == 50)
    }

    @Test("row-space growth keeps the same content visible")
    func driftGrowthKeepsContent() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 30, totalRows: 100)

        #expect(anchor.targetTopRow(postReplayTotalRows: 115, postReplayVisibleRows: 20) == 50)
    }

    @Test("a capped row space preserves distance from bottom")
    func cappedHistoryDegradesToDistanceFromBottom() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 30, totalRows: 200)

        #expect(anchor.targetTopRow(postReplayTotalRows: 200, postReplayVisibleRows: 25) == 145)
    }

    @Test("a distance beyond available history clamps to the top")
    func distanceBeyondHistoryClampsToTop() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 100, totalRows: 150)

        #expect(anchor.targetTopRow(postReplayTotalRows: 50, postReplayVisibleRows: 10) == 0)
    }

    @Test("a viewport longer than the post-replay row space clamps to zero")
    func rowSpaceShorterThanViewportClampsToZero() {
        let anchor = VerifiedReplayViewportAnchor(rowsFromBottom: 1, totalRows: 10)

        #expect(anchor.targetTopRow(postReplayTotalRows: 5, postReplayVisibleRows: 10) == 0)
    }

    @Test("extreme values do not underflow or overflow")
    func extremeValuesDoNotWrap() {
        let anchor = VerifiedReplayViewportAnchor(
            rowsFromBottom: UInt64.max,
            totalRows: 0
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: UInt64.max,
                postReplayVisibleRows: 0
            ) == 0
        )
    }
}
