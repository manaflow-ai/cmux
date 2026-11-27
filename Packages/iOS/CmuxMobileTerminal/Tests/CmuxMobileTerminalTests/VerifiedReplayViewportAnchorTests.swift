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

    @Test("a capped row space without push accounting preserves distance from bottom")
    func cappedHistoryDegradesToDistanceFromBottom() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 55,
            totalRows: 200
        )

        #expect(anchor.targetTopRow(postReplayTotalRows: 200, postReplayVisibleRows: 25) == 145)
    }

    @Test("pushes at the scrollback cap follow the evicted content upward")
    func cappedEvictionFollowsContent() {
        // Pegged at a 4,000-row cap: 250 rows pushed through the grid while
        // the total stayed flat means 250 retained rows were evicted from the
        // top, so the captured content now lives 250 rows higher.
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 3_000,
            totalRows: 4_000,
            rowsPushedAtCapture: 1_000
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 4_000,
                postReplayVisibleRows: 54,
                rowsPushedSinceCapture: 250
            ) == 750
        )
    }

    @Test("below the cap, pushes equal growth and the target is unchanged")
    func belowCapPushesMatchGrowth() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 50,
            totalRows: 100,
            rowsPushedAtCapture: 500
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 115,
                postReplayVisibleRows: 20,
                rowsPushedSinceCapture: 15
            ) == 50
        )
    }

    @Test("reaching the cap mid-window follows content by the evicted remainder")
    func reachingCapMidWindowFollowsContent() {
        // 400 rows pushed while the total only grew by 100: the last 300
        // pushes evicted retained rows, so the content sits 300 rows higher
        // than the pure growth-canceled target.
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 3_000,
            totalRows: 3_900,
            rowsPushedAtCapture: 0
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 4_000,
                postReplayVisibleRows: 54,
                rowsPushedSinceCapture: 400
            ) == 600
        )
    }

    @Test("evicting past the captured content clamps to the scrollback top")
    func evictionPastCapturedContentClampsToTop() {
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 3_900,
            totalRows: 4_000,
            rowsPushedAtCapture: 0
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 4_000,
                postReplayVisibleRows: 54,
                rowsPushedSinceCapture: 500
            ) == 0
        )
    }

    @Test("a rebuilt shorter row space keeps the growth-canceled fallback")
    func rebuiltRowSpaceKeepsFallback() {
        // Hydration collapsed the row space below the captured total; the
        // pushed-rows correction cannot place content in a rebuilt space, so
        // the target degrades to the growth-canceled distance from bottom.
        let anchor = VerifiedReplayViewportAnchor(
            topRowDistanceFromBottom: 55,
            totalRows: 4_000,
            rowsPushedAtCapture: 100
        )

        #expect(
            anchor.targetTopRow(
                postReplayTotalRows: 200,
                postReplayVisibleRows: 25,
                rowsPushedSinceCapture: 40
            ) == 145
        )
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
