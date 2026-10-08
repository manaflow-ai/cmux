import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// The strip offset rules Lawrence asked for (cx-ww20, "unnecessary
/// scroll"), pinned on the reducer: content that fits never scrolls in any
/// centering mode or focus source; focusing a fully visible column does not
/// scroll; a repeated snapshot (layout re-entry) does not scroll; a reveal
/// moves only as far as needed.
struct ColumnScrollRulesTests {
    private let sources: [ColumnFocusSource] = [.keyboard, .pointer, .programmatic, .scroll]

    @Test func contentThatFitsNeverScrolls() {
        let strip = makeStrip([400, 500])
        for mode in [CenterFocusedColumn.never, .always, .onOverflow] {
            for source in sources {
                var state = settledState(strip, focused: "p0", mode: mode)
                state.reduce(.sync(strip, focused: "p1", source: source, animated: false))
                #expect(state.spring.target == 0, "mode \(mode) source \(source)")
                state.reduce(.sync(strip, focused: "p0", source: source, animated: false))
                #expect(state.spring.target == 0, "mode \(mode) source \(source)")
            }
        }
    }

    @Test func focusingAFullyVisibleColumnDoesNotScroll() {
        let strip = makeStrip([400, 400, 400])
        var state = settledState(strip, focused: "p2")
        let offset = state.spring.target
        #expect(offset > 0)
        // p1 is fully visible at this offset.
        for source in sources where source != .scroll {
            var copy = state
            copy.reduce(.sync(strip, focused: "p1", source: source, animated: false))
            #expect(copy.spring.target == offset, "source \(source)")
        }
        state.reduce(.sync(strip, focused: "p2", source: .programmatic, animated: false))
        #expect(state.spring.target == offset, "a repeated snapshot does not scroll")
    }

    @Test func aRevealMovesOnlyAsFarAsNeeded() {
        let strip = makeStrip([400, 400, 400])
        var state = settledState(strip, focused: "p0")
        #expect(state.spring.target == 0)
        state.reduce(.sync(strip, focused: "p2", source: .keyboard, animated: false))
        // The least scroll that shows p2 with its padding: its right edge at the viewport's.
        let p2 = strip.columns[2].frame
        #expect(abs(state.spring.target - strip.clamp(p2.maxX + strip.padding(for: p2.width) - strip.visibleWidth)) < 0.5)
    }
}
