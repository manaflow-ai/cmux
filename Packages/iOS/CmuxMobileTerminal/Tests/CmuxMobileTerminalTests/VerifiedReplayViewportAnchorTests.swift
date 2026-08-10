import Testing

@testable import CmuxMobileTerminal

@Suite("Verified replay viewport anchor")
struct VerifiedReplayViewportAnchorTests {
    @Test("visible-row flicker does not accumulate across replay cycles")
    func lenFlickerDoesNotAccumulateAcrossReplayCycles() throws {
        let totalRows: UInt64 = 4_053
        let initialOffset: UInt64 = 3_990
        var offset = initialOffset

        for _ in 0..<10 {
            let anchor = try #require(
                VerifiedReplayViewportAnchor(
                    scrollbarTotal: totalRows,
                    offset: offset,
                    len: 54
                )
            )
            offset = try #require(
                anchor.targetTopRow(
                    postReplayTotalRows: totalRows,
                    postReplayVisibleRows: 53
                )
            )

            #expect(offset == initialOffset)
        }
    }

    @Test("scrollbar derivation distinguishes bottom from above-bottom")
    func scrollbarDerivation() throws {
        #expect(
            VerifiedReplayViewportAnchor(
                scrollbarTotal: 100,
                offset: 80,
                len: 20
            ) == nil
        )
        #expect(
            VerifiedReplayViewportAnchor(
                scrollbarTotal: 100,
                offset: 80,
                len: 21
            ) == nil
        )

        let anchor = try #require(
            VerifiedReplayViewportAnchor(
                scrollbarTotal: 100,
                offset: 79,
                len: 20
            )
        )
        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 100,
                postReplayVisibleRows: 20
            ) == 79
        )
    }

    @Test("an at-bottom viewport follows replay output naturally")
    func atBottomDoesNotRestore() {
        let anchor = VerifiedReplayViewportAnchor(
            scrollbarTotal: 100,
            offset: 80,
            len: 20
        )

        #expect(anchor == nil)
    }

    @Test("an unchanged row space restores the prior top row")
    func plainRestore() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 50,
            totalRows: 100
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 100, postReplayVisibleRows: 20) == 50)
    }

    @Test("row-space growth keeps the same content visible")
    func driftGrowthKeepsContent() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 50,
            totalRows: 100
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 115, postReplayVisibleRows: 20) == 50)
    }

    @Test("a capped row space preserves distance from bottom")
    func cappedHistoryDegradesToDistanceFromBottom() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 55,
            totalRows: 200
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 200, postReplayVisibleRows: 25) == 145)
    }

    @Test("a distance beyond available history clamps to the top")
    func distanceBeyondHistoryClampsToTop() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 110,
            totalRows: 150
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 50, postReplayVisibleRows: 10) == 0)
    }

    @Test("a viewport longer than the post-replay row space clamps to zero")
    func rowSpaceShorterThanViewportClampsToZero() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 11,
            totalRows: 10
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 5, postReplayVisibleRows: 10) == 0)
    }

    @Test("extreme values do not underflow or overflow")
    func extremeValuesDoNotWrap() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: UInt64.max,
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
