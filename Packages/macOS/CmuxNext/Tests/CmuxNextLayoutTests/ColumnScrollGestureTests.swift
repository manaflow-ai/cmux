import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Trackpad and wheel scrolling of the strip (plans/cmux-next/niri.md,
/// "Trackpad and wheel").
struct ColumnScrollGestureTests {
    private let four = makeStrip([400, 400, 400, 400])

    /// Drags by `total` points over `steps` events 8 ms apart, from `start`.
    private func drag(_ state: inout ColumnScrollState, total: CGFloat, steps: Int = 10, start: Double = 0) -> Double {
        state.reduce(.gestureBegan)
        var time = start
        for _ in 0..<steps {
            time += 0.008
            state.reduce(.gestureChanged(deltaX: -total / CGFloat(steps), time: time))
        }
        return time
    }

    @Test func aGestureTakesOverAnAutomaticScrollWhereItIs() {
        var state = settledState(four, focused: "p0")
        state.focus("p3")
        for _ in 0..<5 { _ = state.spring.advance(1.0 / 120.0, parameters: .init(response: 0.22, dampingFraction: 0.9), epsilon: 0.25) }
        let presented = state.spring.value
        state.reduce(.gestureBegan)
        #expect(state.spring.value == presented)
        #expect(state.spring.target == presented)
        #expect(state.spring.velocity == 0)
    }

    @Test func focusChangesDuringAGestureDoNotFightIt() {
        var state = settledState(four, focused: "p0")
        _ = drag(&state, total: 100)
        let value = state.spring.value
        state.focus("p3")
        state.reduce(.sync(makeStrip([400, 400, 400, 400, 400]), focused: "p3", source: .programmatic, animated: true))
        #expect(state.spring.value == value)
        #expect(state.spring.target == value)
    }

    @Test func releaseSnapsToAColumnEdgeAndKeepsAVisibleFocus() {
        var state = settledState(four, focused: "p1")
        let end = drag(&state, total: 150, steps: 30)
        let effects = state.reduce(.gestureEnded(time: end + 0.2, animated: false))
        // Slow release near 150: snaps to an edge, c1 (416...816) still shows.
        #expect(ColumnViewOffset.snaps(strip: four, mode: .never).map(\.offset).contains(state.spring.value))
        #expect(effects.focus == nil)
        #expect(effects.reportOnSettle)
    }

    @Test func scrollingTheFocusOffScreenMovesFocusTheNiriWay() {
        var state = settledState(four, focused: "p0")
        let end = drag(&state, total: 640, steps: 20)
        let effects = state.reduce(.gestureEnded(time: end + 0.2, animated: false))
        #expect(state.spring.value == 640)
        // Forward gesture: the farthest fully visible column (c3) takes focus.
        #expect(effects.focus == "p3")
        // The model's echo of that focus does not scroll.
        state.reduce(.sync(four, focused: "p3", source: .scroll, animated: true))
        #expect(state.spring.target == 640)
    }

    @Test func rubberBandPastTheEndsSpringsBack() {
        var state = settledState(four, focused: "p0")
        let end = drag(&state, total: -300)
        #expect(state.spring.value < 0 && state.spring.value > -300)
        state.reduce(.gestureEnded(time: end + 0.2, animated: true))
        #expect(state.spring.target == 0)
        state.runToRest()
        #expect(state.spring.value == 0)
    }

    @Test func aFlingAdvancesAtLeastOneSnapAndCarriesVelocity() {
        var state = settledState(four, focused: "p0")
        let end = drag(&state, total: 40, steps: 4)
        state.reduce(.gestureEnded(time: end + 0.001, animated: true))
        #expect(state.spring.target > 40)
        #expect(state.spring.velocity > 300)
    }

    @Test func wheelNotchesStepSnapsAndKeepTheFocusVisible() {
        var state = settledState(four, focused: "p0")
        var effects = state.reduce(.wheel(direction: 1, animated: false))
        #expect(state.spring.value == 232)
        // c0 left the view: the farthest visible column forward takes focus.
        #expect(effects.focus == "p2")
        for _ in 0..<6 { effects = state.reduce(.wheel(direction: 1, animated: false)) }
        #expect(state.spring.value == 640)
        #expect(state.focusedPane != "p0")
        _ = effects
        state.reduce(.wheel(direction: -1, animated: false))
        #expect(state.spring.value < 640)
    }

    @Test func alwaysModeSnapsToColumnCenters() {
        let snaps = ColumnViewOffset.snaps(strip: four, mode: .always).map(\.offset)
        // Centers 208, 616, 1024, 1432 minus 500, clamped to 0...640.
        #expect(snaps == [0, 116, 524, 640])
    }

    @Test func neverModeSnapsToEdges() {
        let snaps = ColumnViewOffset.snaps(strip: makeStrip([600, 500, 400], gap: 0), mode: .never).map(\.offset)
        #expect(snaps == [0, 100, 500])
    }

    @Test func onOverflowSnapsToCentersBesideWideNeighbors() {
        let snaps = ColumnViewOffset.snaps(strip: makeStrip([700, 700, 700]), mode: .onOverflow).map(\.offset)
        // Neighbors overflow: edges beside them snap to centers (566), ends clamp.
        #expect(snaps == [0, 566, 1132])
    }
}
