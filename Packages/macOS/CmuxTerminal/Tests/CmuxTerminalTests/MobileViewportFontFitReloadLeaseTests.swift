import Testing

@testable import CmuxTerminal

@Suite("Mobile viewport font-fit reload lease")
struct MobileViewportFontFitReloadLeaseTests {
    @Test func staleReloadCompletionCannotConsumeNewerLease() throws {
        var state = MobileViewportFontFitReloadLeaseState()
        let firstLimit = MobileViewportCellLimit(
            generation: 1,
            columns: 80,
            rows: 24
        )
        let first = state.prepare(
            viewportLimit: firstLimit,
            surrendered: true,
            userAdjustedBaseFontPointSize: nil
        )
        let secondLimit = MobileViewportCellLimit(
            generation: 2,
            columns: 100,
            rows: 30
        )
        let second = state.prepare(
            viewportLimit: secondLimit,
            surrendered: false,
            userAdjustedBaseFontPointSize: 14
        )

        #expect(state.consume(generation: first.generation) == nil)
        #expect(state.pendingGeneration == second.generation)

        let completedLease = state.consume(generation: second.generation)
        let consumed = try #require(completedLease)
        #expect(consumed.viewportGeneration == secondLimit.generation)
        #expect(consumed.refitLimit(current: secondLimit) == secondLimit)
        #expect(consumed.userAdjustedBaseFontPointSize == 14)
        #expect(state.pendingGeneration == nil)
    }

    @Test func reloadLeaseRefitsNewerAuthoritativeViewport() {
        var state = MobileViewportFontFitReloadLeaseState()
        let original = MobileViewportCellLimit(
            generation: 1,
            columns: 80,
            rows: 24
        )
        let lease = state.prepare(
            viewportLimit: original,
            surrendered: true,
            userAdjustedBaseFontPointSize: nil
        )
        let rotated = MobileViewportCellLimit(
            generation: 2,
            columns: 42,
            rows: 82
        )

        #expect(lease.refitLimit(current: rotated) == rotated)
        #expect(lease.refitLimit(current: nil) == nil)
    }
}
