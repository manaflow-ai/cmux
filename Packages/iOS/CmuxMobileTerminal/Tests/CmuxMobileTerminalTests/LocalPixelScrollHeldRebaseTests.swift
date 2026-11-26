import Testing

@testable import CmuxMobileTerminal

@Suite("Local pixel scroll held rebase")
struct LocalPixelScrollHeldRebaseTests {
    private let cellHeightPx = 20.0

    @Test("eviction at the cap slides the held position up by the evicted rows")
    func evictionAtCapFollowsContent() {
        // Pegged at the cap: 30 rows pushed with zero growth means 30 rows
        // evicted from the top, so the same content is 30 rows (600px) higher.
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 4_000,
            heldRowsPushed: 100,
            scrollbarTotal: 4_000,
            rowsPushedNow: 130,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == 20_000 - 30 * cellHeightPx)
    }

    @Test("growth below the cap keeps the held position unchanged")
    func growthBelowCapKeepsPosition() {
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 3_000,
            heldRowsPushed: 100,
            scrollbarTotal: 3_050,
            rowsPushedNow: 150,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == 20_000)
    }

    @Test("partial eviction subtracts only the pushes beyond growth")
    func partialEvictionSubtractsRemainder() {
        // 50 pushed, 20 absorbed as growth to the cap, 30 evicted.
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 3_980,
            heldRowsPushed: 100,
            scrollbarTotal: 4_000,
            rowsPushedNow: 150,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == 20_000 - 30 * cellHeightPx)
    }

    @Test("eviction past the held content clamps to the scrollback top")
    func evictionPastHeldContentClampsToTop() {
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 100,
            heldTotal: 4_000,
            heldRowsPushed: 0,
            scrollbarTotal: 4_000,
            rowsPushedNow: 50,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == 0)
    }

    @Test("a shrunk row space cannot be reconciled")
    func shrunkRowSpaceIsUntrusted() {
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 4_000,
            heldRowsPushed: 100,
            scrollbarTotal: 200,
            rowsPushedNow: 150,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == nil)
    }

    @Test("a rewound push counter cannot be reconciled")
    func rewoundCounterIsUntrusted() {
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 4_000,
            heldRowsPushed: 100,
            scrollbarTotal: 4_000,
            rowsPushedNow: 50,
            cellHeightPx: cellHeightPx
        )

        #expect(corrected == nil)
    }

    @Test("a degenerate cell height cannot be reconciled")
    func degenerateCellHeightIsUntrusted() {
        let corrected = GhosttySurfaceView.LocalPixelScrollState.rebasedHeldPositionPx(
            heldPositionPx: 20_000,
            heldTotal: 4_000,
            heldRowsPushed: 100,
            scrollbarTotal: 4_000,
            rowsPushedNow: 130,
            cellHeightPx: 0
        )

        #expect(corrected == nil)
    }
}

@Suite("Gesture base position")
struct GestureBasePositionTests {
    private let cellHeightPx = 20.0

    private func held(
        positionPx: Double,
        revision: UInt64,
        total: UInt64,
        rowsPushed: UInt64 = 0,
        dockedAtTail: Bool
    ) -> GhosttySurfaceView.LocalPixelScrollState.Held {
        .init(
            row: UInt64(positionPx / cellHeightPx),
            remainderPx: 0,
            positionPx: positionPx,
            revision: revision,
            total: total,
            rowsPushed: rowsPushed,
            dockedAtTail: dockedAtTail
        )
    }

    @Test("a docked hold targets the live tail after output grew the row space")
    func dockedHoldFollowsGrownTail() {
        // Docked at total=1000 (position 18,800); 12 rows arrived since the
        // batch. Content anchoring would leave the viewport 12 rows behind
        // the new bottom; the docked hold must target the LIVE tail.
        let base = GhosttySurfaceView.LocalPixelScrollState.gestureBasePositionPx(
            rebaseFromHeldPosition: true,
            held: held(positionPx: 18_800, revision: 3, total: 1_000, dockedAtTail: true),
            scrollbarOffset: 952,
            scrollbarRevision: 3,
            scrollbarTotal: 1_012,
            rowsPushedNow: 12,
            remainderPx: 0,
            cellHeightPx: cellHeightPx,
            maxPositionPx: 19_040
        )

        #expect(base == 19_040)
    }

    @Test("a docked hold survives a row-space revision change at the cap")
    func dockedHoldSurvivesEviction() {
        // Eviction at the cap bumps the revision; the tail is still the
        // tail, so a docked hold keeps targeting the live bottom instead of
        // rebasing content-true away from it.
        let base = GhosttySurfaceView.LocalPixelScrollState.gestureBasePositionPx(
            rebaseFromHeldPosition: true,
            held: held(positionPx: 78_800, revision: 3, total: 4_000, rowsPushed: 100, dockedAtTail: true),
            scrollbarOffset: 3_940,
            scrollbarRevision: 4,
            scrollbarTotal: 4_000,
            rowsPushedNow: 130,
            remainderPx: 0,
            cellHeightPx: cellHeightPx,
            maxPositionPx: 78_800
        )

        #expect(base == 78_800)
    }

    @Test("an undocked hold keeps its content while output grows")
    func undockedHoldKeepsContent() {
        let base = GhosttySurfaceView.LocalPixelScrollState.gestureBasePositionPx(
            rebaseFromHeldPosition: true,
            held: held(positionPx: 10_000, revision: 3, total: 1_000, dockedAtTail: false),
            scrollbarOffset: 952,
            scrollbarRevision: 3,
            scrollbarTotal: 1_012,
            rowsPushedNow: 12,
            remainderPx: 0,
            cellHeightPx: cellHeightPx,
            maxPositionPx: 19_040
        )

        #expect(base == 10_000)
    }

    @Test("an undocked hold rebases content-true across eviction")
    func undockedHoldRebasesAcrossEviction() {
        // 30 pushed with zero growth at the cap: same content is 30 rows up.
        let base = GhosttySurfaceView.LocalPixelScrollState.gestureBasePositionPx(
            rebaseFromHeldPosition: true,
            held: held(positionPx: 20_000, revision: 3, total: 4_000, rowsPushed: 100, dockedAtTail: false),
            scrollbarOffset: 900,
            scrollbarRevision: 4,
            scrollbarTotal: 4_000,
            rowsPushedNow: 130,
            remainderPx: 0,
            cellHeightPx: cellHeightPx,
            maxPositionPx: 78_800
        )

        #expect(base == 20_000 - 30 * cellHeightPx)
    }

    @Test("an idle batch trusts the live viewport")
    func idleBatchTrustsLiveViewport() {
        let base = GhosttySurfaceView.LocalPixelScrollState.gestureBasePositionPx(
            rebaseFromHeldPosition: false,
            held: held(positionPx: 10_000, revision: 3, total: 1_000, dockedAtTail: true),
            scrollbarOffset: 100,
            scrollbarRevision: 3,
            scrollbarTotal: 1_000,
            rowsPushedNow: 0,
            remainderPx: 4,
            cellHeightPx: cellHeightPx,
            maxPositionPx: 18_800
        )

        #expect(base == 100 * cellHeightPx + 4)
    }
}
