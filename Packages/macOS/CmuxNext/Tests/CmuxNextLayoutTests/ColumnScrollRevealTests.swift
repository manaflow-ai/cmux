import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Focus reveal rules (plans/cmux-next/niri.md, "Focus"). Viewport 1000,
/// gap 8; three 600 pt columns sit at 8, 616 and 1224 (max offset 832).
struct ColumnScrollRevealTests {
    private let wide3 = makeStrip([600, 600, 600])

    @Test func firstPlacementIsInstantAndMinimal() {
        let state = settledState(wide3, focused: "p2")
        #expect(state.spring.value == 832)
        #expect(state.spring.target == 832)
    }

    @Test func keyboardFocusScrollsTheLeastAmount() {
        var state = settledState(wide3, focused: "p0")
        state.focus("p1")
        // Right edge plus the gap at the viewport edge: 1216 + 8 - 1000.
        #expect(state.spring.target == 224)
        #expect(state.spring.value == 0)
        state.runToRest()
        state.focus("p0")
        #expect(state.spring.target == 0)
    }

    @Test func aVisibleColumnNeverScrolls() {
        var state = settledState(makeStrip([300, 300, 300, 300]), focused: "p0")
        for pane in ["p2", "p1", "p0"] {
            state.focus(pane, source: .keyboard)
            #expect(state.spring.target == 0)
            state.focus(pane, source: .pointer)
            #expect(state.spring.target == 0)
        }
    }

    @Test func clickOnAPartlyVisibleColumnRevealsItMinimallyEvenWhenCentering() {
        var state = settledState(wide3, focused: "p0", mode: .always)
        state.focus("p1", source: .pointer)
        #expect(state.spring.target == 224)
        state.runToRest()
        // A later keyboard focus uses the mode again.
        state.focus("p2", source: .keyboard)
        #expect(state.spring.target == 832)
    }

    @Test func firstAndLastColumnsClampToTheStripEnds() {
        var state = settledState(wide3, focused: "p1", mode: .always)
        state.focus("p0")
        #expect(state.spring.target == 0)
        state.focus("p2")
        #expect(state.spring.target == 832)
    }

    @Test func alwaysCentersTheFocusedColumn() {
        var state = settledState(makeStrip([400, 400, 400, 400]), focused: "p0", mode: .always)
        state.focus("p2")
        // c2 spans 824...1224, midX 1024.
        #expect(state.spring.target == 524)
    }

    @Test func onOverflowCentersOnlyWhenBothColumnsCannotShare() {
        var state = settledState(wide3, focused: "p0", mode: .onOverflow)
        state.focus("p1")
        // c0 + c1 + gaps = 1224 > 1000: center c1 (midX 916).
        #expect(state.spring.target == 416)

        var narrow = settledState(makeStrip([300, 300, 300, 300, 300]), focused: "p2", mode: .onOverflow)
        narrow.focus("p3")
        // c2 + c3 fit together: minimal reveal of c3 (932...1232).
        #expect(narrow.spring.target == 240)
    }

    @Test func differentWidthsAlignTheNearerEdge() {
        var state = settledState(makeStrip([300, 900, 200, 500]), focused: "p0")
        state.focus("p1")
        // c1 316...1216 aligns its right edge.
        #expect(state.spring.target == 224)
        state.runToRest()
        state.focus("p3")
        // c3 1432...1932.
        #expect(state.spring.target == 940)
        state.runToRest()
        state.focus("p2")
        // c2 1224...1424 is visible at 940.
        #expect(state.spring.target == 940)
    }

    @Test func aColumnWiderThanTheViewAlignsItsLeftEdgeOrKeepsThePaneVisible() {
        var strip = makeStrip([400, 1400, 400])
        let wide = strip.columns[1].frame
        let left = CGRect(x: wide.minX, y: 0, width: 696, height: 600)
        let right = CGRect(x: wide.minX + 704, y: 0, width: 696, height: 600)
        strip.columns[1].panes = ["pa", "pb"]
        strip.columns[1].paneFrames = ["pa": left, "pb": right]
        var state = settledState(strip, focused: "p0")
        state.focus("pa")
        #expect(state.spring.target == wide.minX)
        state.runToRest()
        state.focus("pb")
        // pb 1120...1816: least scroll that shows it.
        #expect(state.spring.target == right.maxX + 8 - 1000)
        state.runToRest()
        state.focus("pb")
        #expect(state.spring.target == right.maxX + 8 - 1000)
        state.focus("pa")
        #expect(state.spring.target == wide.minX)
    }

    @Test func aFastFocusSequenceRetargetsFromThePresentedValue() {
        var state = settledState(wide3, focused: "p0")
        state.focus("p1")
        for _ in 0..<6 { _ = state.spring.advance(1.0 / 120.0, parameters: .init(response: 0.22, dampingFraction: 0.9), epsilon: 0.25) }
        let midway = state.spring.value
        let velocity = state.spring.velocity
        #expect(midway > 0 && midway < 224)
        state.focus("p2")
        state.focus("p1")
        state.focus("p2")
        // No jump and no queue: same presented value and velocity, newest target.
        #expect(state.spring.value == midway)
        #expect(state.spring.velocity == velocity)
        #expect(state.spring.target == 832)
        let values = state.runToRest()
        #expect(values.last == 832)
        #expect(zip(values, values.dropFirst()).allSatisfy { $1 >= $0 - 0.5 })
    }

    @Test func reduceMotionOrOffSnaps() {
        var state = settledState(wide3, focused: "p0")
        state.focus("p2", animated: false)
        #expect(state.spring.value == 832)
    }

    @Test func centerRequestCentersOnce() {
        var state = settledState(makeStrip([400, 400, 400, 400]), focused: "p0")
        state.reduce(.center("p1", animated: false))
        #expect(state.spring.value == 116)
    }

    @Test func configValuesParse() {
        #expect(CenterFocusedColumn(configValue: "never") == .never)
        #expect(CenterFocusedColumn(configValue: "Always") == .always)
        #expect(CenterFocusedColumn(configValue: "on-overflow") == .onOverflow)
        #expect(CenterFocusedColumn(configValue: "sometimes") == nil)
    }
}
