#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@Suite("Local pixel scroll anchor seeding")
struct LocalPixelScrollSeedTests {
    @Test("an idle authority accepts the replay anchor seed")
    func seedsWhenIdle() {
        var state = GhosttySurfaceView.LocalPixelScrollState()
        state.remainderPx = 4

        let seeded = state.seedHeldPositionIfIdle(
            row: 120,
            positionPx: 3_840,
            revision: 5,
            total: 400,
            epoch: 0
        )

        #expect(seeded)
        #expect(state.lastApplied?.row == 120)
        #expect(state.lastApplied?.positionPx == 3_840)
        #expect(state.lastApplied?.revision == 5)
        #expect(state.lastApplied?.total == 400)
        #expect(state.lastApplied?.remainderPx == 0)
        #expect(state.remainderPx == 0)
    }

    @Test("a live gesture's held position is never overwritten by a seed")
    func keepsLiveGestureAuthority() {
        var state = GhosttySurfaceView.LocalPixelScrollState()
        state.lastApplied = (
            row: 10,
            remainderPx: 2,
            positionPx: 322,
            revision: 5,
            total: 400
        )

        let seeded = state.seedHeldPositionIfIdle(
            row: 120,
            positionPx: 3_840,
            revision: 5,
            total: 400,
            epoch: 0
        )

        #expect(!seeded)
        #expect(state.lastApplied?.row == 10)
        #expect(state.lastApplied?.positionPx == 322)
    }

    @Test("an epoch bump between capture and seed voids the seed")
    func epochBumpVoidsSeed() {
        var state = GhosttySurfaceView.LocalPixelScrollState()
        state.epoch = 3

        let seeded = state.seedHeldPositionIfIdle(
            row: 120,
            positionPx: 3_840,
            revision: 5,
            total: 400,
            epoch: 2
        )

        #expect(!seeded)
        #expect(state.lastApplied == nil)
    }
}
#endif
