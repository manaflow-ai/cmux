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
