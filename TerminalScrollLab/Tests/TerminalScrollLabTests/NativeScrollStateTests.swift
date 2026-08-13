import CoreGraphics
import Testing

@testable import TerminalScrollLab

@Suite("Native pixel scroll state")
struct NativeScrollStateTests {
    @Test("sub-row movement stays pixel continuous across a row flip")
    func subRowMovement() {
        var state = NativeScrollState(initialOffsetY: 1_000)

        let quarter = state.sample(
            rawOffsetY: 995,
            maximumOffsetY: 1_000,
            cellHeight: 20
        )
        #expect(quarter.targetViewportRow == 50)
        #expect(quarter.presentationTranslationY == 5)

        let crossedRow = state.sample(
            rawOffsetY: 975,
            maximumOffsetY: 1_000,
            cellHeight: 20
        )
        #expect(crossedRow.targetViewportRow == 49)
        #expect(crossedRow.presentationTranslationY == 25)

        state.updateAuthoritativeOffsetY(980)
        let reconciled = state.sample(
            rawOffsetY: 975,
            maximumOffsetY: 1_000,
            cellHeight: 20
        )
        #expect(reconciled.targetViewportRow == 49)
        #expect(reconciled.presentationTranslationY == 5)
    }

    @Test("rubber band translates without emitting out-of-range scroll")
    func rubberBand() {
        var state = NativeScrollState(initialOffsetY: 1_000)
        let sample = state.sample(
            rawOffsetY: 1_018,
            maximumOffsetY: 1_000,
            cellHeight: 20
        )

        #expect(sample.effectiveOffsetY == 1_000)
        #expect(sample.targetViewportRow == 50)
        #expect(sample.presentationTranslationY == -18)
    }

    @Test("reversing direction preserves the fractional viewport")
    func reversal() {
        var state = NativeScrollState(initialOffsetY: 1_000)
        _ = state.sample(rawOffsetY: 987, maximumOffsetY: 1_000, cellHeight: 20)
        let reversed = state.sample(rawOffsetY: 993, maximumOffsetY: 1_000, cellHeight: 20)

        #expect(reversed.targetViewportRow == 50)
        #expect(reversed.presentationTranslationY == 7)
    }

    @Test("renderer lag cannot pull presentation more than two rows")
    func rendererLagClamp() {
        var state = NativeScrollState(initialOffsetY: 1_000)
        let sample = state.sample(
            rawOffsetY: 900,
            maximumOffsetY: 1_000,
            cellHeight: 20
        )

        #expect(sample.presentationTranslationY == 40)
    }
}
