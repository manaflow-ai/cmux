import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Layout changes under the column scroll (plans/cmux-next/column-scroll.md,
/// "Layout changes"): close, open, resize, move, window resize.
struct ColumnScrollLayoutTests {
    @Test func closingTheRightmostColumnSpringsBackWithNoJump() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        #expect(state.spring.value == 832)
        let effects = state.reduce(.sync(makeStrip([600, 600]), focused: "p1", source: .programmatic, animated: true))
        // The camera does not jump; it springs to the new end (1224 - 1000).
        #expect(state.spring.value == 832)
        #expect(state.spring.target == 224)
        #expect(effects.needsFrames)
        let values = state.runToRest()
        #expect(values.last == 224)
        #expect(zip(values, values.dropFirst()).allSatisfy { $1 <= $0 + 0.5 })
        // Settled: no empty space right of the last column.
        #expect(state.screenX(of: "c1").map { $0 + 600 + 8 } == 1000)
    }

    @Test func closingTheRightmostColumnWithoutAnimationSnaps() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        state.reduce(.sync(makeStrip([600, 600]), focused: "p1", source: .programmatic, animated: false))
        #expect(state.spring.value == 224)
    }

    @Test func closingAColumnLeftOfTheFocusKeepsTheFocusedColumnStill() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        let before = state.screenX(of: "c2")
        let effects = state.reduce(.sync(makeStrip([600, 600], ids: ["0", "2"]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.screenX(of: "c2") == before)
        #expect(state.spring.target == state.spring.value)
        #expect(!effects.needsFrames)
    }

    @Test func closingTheFocusedMiddleColumnRevealsItsSuccessorMinimally() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p0")
        state.focus("p1")
        state.runToRest()
        #expect(state.spring.value == 224)
        // The daemon focuses the right neighbor, which slid into place (616...1216).
        state.reduce(.sync(makeStrip([600, 600], ids: ["0", "2"]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.spring.value == 224)
        #expect(state.spring.target == 224)
    }

    @Test func closingTheFocusedLeftmostColumnDoesNotScroll() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p0")
        state.reduce(.sync(makeStrip([600, 600], ids: ["1", "2"]), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.value == 0)
        #expect(state.spring.target == 0)
    }

    @Test func openingAColumnRightOfTheFocusRevealsItAndClosingItRestoresTheView() {
        var state = settledState(makeStrip([400, 400, 400, 400]), focused: "p0")
        state.focus("p2")
        state.runToRest()
        state.focus("p1")
        state.runToRest()
        #expect(state.spring.value == 232)
        // New 600 pt column right of c1, focused.
        let opened = makeStrip([400, 400, 600, 400, 400], ids: ["0", "1", "n", "2", "3"])
        state.reduce(.sync(opened, focused: "pn", source: .programmatic, animated: true))
        #expect(state.screenX(of: "c1") == CGFloat(184))
        #expect(state.spring.target == 432)
        state.runToRest()
        // Closing it returns focus left and restores the old view (the
        // restore point), not merely a minimal reveal (408).
        state.reduce(.sync(makeStrip([400, 400, 400, 400]), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.target == 232)
    }

    @Test func focusingElsewhereForgetsTheRestorePoint() {
        var state = settledState(makeStrip([400, 400, 400, 400]), focused: "p1")
        let opened = makeStrip([400, 400, 600, 400, 400], ids: ["0", "1", "n", "2", "3"])
        state.reduce(.sync(opened, focused: "pn", source: .programmatic, animated: false))
        #expect(state.restore != nil)
        state.focus("p3", animated: false)
        #expect(state.restore == nil)
    }

    @Test func openingAColumnLeftOfTheFocusKeepsTheFocusedColumnStill() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        let before = state.screenX(of: "c2")
        state.reduce(.sync(makeStrip([600, 300, 600, 600], ids: ["0", "n", "1", "2"]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.screenX(of: "c2") == before)
    }

    @Test func wideningTheFocusedColumnAtTheRightEdgeRevealsItsNewEdge() {
        var state = settledState(makeStrip([600, 600]), focused: "p1")
        #expect(state.spring.value == 224)
        state.reduce(.sync(makeStrip([600, 800]), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.target == 424)
    }

    @Test func resizingAColumnLeftOfTheFocusKeepsTheFocusedColumnStill() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        let before = state.screenX(of: "c2")
        state.reduce(.sync(makeStrip([400, 600, 600]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.screenX(of: "c2") == before)
        #expect(state.spring.target == 632)
    }

    @Test func movingTheFocusedColumnKeepsTheCameraThenRevealsIt() {
        var state = settledState(makeStrip([400, 400, 400, 400]), focused: "p0")
        state.focus("p2")
        state.runToRest()
        #expect(state.spring.value == 232)
        // Move c2 right: order 0, 1, 3, 2. c2 is now 1232...1632.
        state.reduce(.sync(makeStrip([400, 400, 400, 400], ids: ["0", "1", "3", "2"]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.spring.value == 232)
        #expect(state.spring.target == 640)
        state.runToRest()
        // Move it left again: 824...1224 is visible at 640, nothing scrolls.
        state.reduce(.sync(makeStrip([400, 400, 400, 400]), focused: "p2", source: .programmatic, animated: true))
        #expect(state.spring.target == 640)
    }

    @Test func windowResizeKeepsTheFocusedColumnInPlaceThenFits() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p0")
        state.focus("p1", animated: false)
        #expect(state.screenX(of: "c1") == 392)
        state.reduce(.sync(makeStrip([720, 720, 720], viewport: 1200), focused: "p1", source: .programmatic, animated: false))
        #expect(state.screenX(of: "c1") == 392)
        // Narrower window: c1 no longer fits where it was; fit it.
        state.reduce(.sync(makeStrip([480, 480, 480], viewport: 800), focused: "p1", source: .programmatic, animated: false))
        let x = state.screenX(of: "c1") ?? -1
        #expect(x >= 8 && x + 480 + 8 <= 800)
    }

    @Test func switchingToASplitScreenOrEmptyStripClampsToZero() {
        var state = settledState(makeStrip([600, 600, 600]), focused: "p2")
        state.reduce(.sync(makeStrip([]), focused: nil, source: .programmatic, animated: true))
        #expect(state.spring.target == 0)
    }
}

/// A column-edge drag keeps the view and fits the
/// focused column once the drag ends.
struct ColumnScrollResizeDragTests {
    @Test func liveResizeHoldsTheViewAndRevealsAtTheEnd() {
        var state = settledState(makeStrip([600, 600]), focused: "p1")
        state.reduce(.sync(makeStrip([600, 800]), focused: "p1", source: .programmatic, animated: false, reveals: false))
        #expect(state.spring.value == 224)
        state.reduce(.sync(makeStrip([600, 800]), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.target == 424)
    }
}
