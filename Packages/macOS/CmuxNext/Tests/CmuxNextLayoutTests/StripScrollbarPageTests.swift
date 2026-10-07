import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// A scrollbar track click or thumb release is a scroll like a wheel notch
/// (dock-column.md B3, column-scroll.md T3): it rests on the target, moves focus
/// when the focused column left the view, and reports the leading column.
@Suite struct StripScrollbarPageTests {
    @Test func aPageThatHidesTheFocusedColumnMovesFocusAlong() {
        let strip = makeStrip([600, 600, 600])
        var state = settledState(strip, focused: "p0")
        #expect(state.spring.target == 0)
        let effects = state.reduce(.page(to: 832, animated: false))
        #expect(state.spring.value == 832)
        #expect(effects.focus == "p2")
        #expect(effects.reportOnSettle)
    }

    @Test func aPageKeepsAFocusedColumnThatStaysVisible() {
        let strip = makeStrip([300, 300, 300, 300, 300])
        var state = settledState(strip, focused: "p2")
        let effects = state.reduce(.page(to: 316, animated: true))
        #expect(state.spring.target == 316)
        #expect(effects.focus == nil)
        #expect(effects.needsFrames)
    }

    @Test func aPageIsClampedToTheStrip() {
        let strip = makeStrip([600, 600])
        var state = settledState(strip, focused: "p0")
        state.reduce(.page(to: 5000, animated: false))
        #expect(state.spring.value == strip.maxOffset)
    }
}
