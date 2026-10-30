import CoreGraphics
@testable import CmuxNextBrowser
import Testing

/// A two-finger swipe over a Chromium page goes Back or Forward only when the page would not
/// scroll that way (plans/cmux-next/history.md 4.2): a carousel, a wide table or a page
/// scrolled sideways keeps the gesture.
@Suite struct BrowserSwipeGestureTests {
    static let atEdges = BrowserSwipeEdges(canScrollLeft: false, canScrollRight: false, consumesHorizontal: false)

    /// Began, answers the first probe, then moves `steps` events of (`dx`, `dy`).
    private func gesture(first: BrowserSwipeEdges? = atEdges, dx: CGFloat, dy: CGFloat = 0,
                         steps: Int = 4) -> (BrowserSwipeGesture, [BrowserSwipeGesture.Step]) {
        var gesture = BrowserSwipeGesture()
        var steps_: [BrowserSwipeGesture.Step] = [gesture.scroll(.began, deltaX: 0, deltaY: 0)]
        gesture.probeAnswered(first, generation: gesture.generation)
        for _ in 0..<steps { steps_.append(gesture.scroll(.changed, deltaX: dx, deltaY: dy)) }
        return (gesture, steps_)
    }

    @Test func aSidewaysSwipeAtTheEdgeProbesAgainThenTracks() {
        var (gesture, steps) = gesture(dx: 3)
        #expect(steps == [.probe, .none, .probe, .none, .none])
        #expect(gesture.phase == .confirming(.back))
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .track(.back))
        #expect(gesture.phase == .tracking(.back))
        // Tracking owns the gesture until the swipe completes.
        #expect(gesture.scroll(.ended, deltaX: 0, deltaY: 0) == .none)
        gesture.swipeFinished()
        #expect(gesture.phase == .idle)
    }

    @Test func contentDraggedLeftIsForward() {
        var (gesture, _) = gesture(dx: -3)
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        #expect(gesture.scroll(.changed, deltaX: -3, deltaY: 0) == .track(.forward))
    }

    @Test func aPageThatScrollsThatWayKeepsTheGesture() {
        // Scrolled away from its left edge: Back scrolls the page.
        let scrolled = BrowserSwipeEdges(canScrollLeft: true, canScrollRight: false, consumesHorizontal: false)
        let (declined, steps) = gesture(first: scrolled, dx: 3)
        #expect(declined.phase == .declined)
        #expect(!steps.contains { if case .track = $0 { true } else { false } })
        // The same page still swipes Forward: it cannot scroll right.
        var (forward, _) = gesture(first: scrolled, dx: -3)
        forward.probeAnswered(scrolled, generation: forward.generation)
        #expect(forward.scroll(.changed, deltaX: -3, deltaY: 0) == .track(.forward))
    }

    @Test func aScriptThatTookTheWheelsKeepsTheGesture() {
        // The first probe only installed the listener; the second sees the carousel's preventDefault.
        var (gesture, _) = gesture(dx: 3)
        gesture.probeAnswered(BrowserSwipeEdges(canScrollLeft: false, canScrollRight: false, consumesHorizontal: true),
                              generation: gesture.generation)
        #expect(gesture.phase == .declined)
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .none)
    }

    @Test func aPageThatCouldNotBeAskedKeepsTheGesture() {
        var (gesture, _) = gesture(first: nil, dx: 3)
        gesture.probeAnswered(nil, generation: gesture.generation)
        #expect(gesture.phase == .declined)
    }

    @Test func aMostlyVerticalScrollNeverSwipes() {
        let (gesture, steps) = gesture(dx: 2, dy: 4)
        #expect(gesture.phase == .declined)
        #expect(steps.filter { $0 == .probe }.count == 1)
    }

    @Test func fingersTurningBackBeforeTheSwipeStartsLeaveItToThePage() {
        var (gesture, _) = gesture(dx: 3)
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        #expect(gesture.scroll(.changed, deltaX: -20, deltaY: 0) == .none)
        #expect(gesture.phase == .declined)
    }

    /// The layout took the gesture (Command at the touch, released before it began: the layout
    /// owns it, the modifier keys say nothing). Even at the scroll edge, ready to track, it never
    /// becomes a swipe, so `trackSwipeEvent` never eats the layout's events and its end
    /// (review 1 of pl-scroll). The next gesture swipes again.
    @Test func aGestureTheLayoutTookNeverSwipes() {
        var (gesture, _) = gesture(dx: 3)
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        #expect(gesture.phase == .ready(.back))
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0, takenByLayout: true) == .none)
        #expect(gesture.phase == .declined)
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .none, "declined until the gesture ends")
        _ = gesture.scroll(.ended, deltaX: 0, deltaY: 0)
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0) == .probe)
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        for _ in 0..<2 { _ = gesture.scroll(.changed, deltaX: 4, deltaY: 0) }
        gesture.probeAnswered(Self.atEdges, generation: gesture.generation)
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .track(.back))
    }

    /// The layout decided at the touch (`mayBegin`, before `began`) that a Command gesture is its own: the
    /// page is never probed (no JavaScript round trip for a gesture that can never swipe), and the
    /// gesture stays declined until it ends (review of pl-scroll, minor 4).
    @Test func aGestureTheLayoutTookAtItsTouchIsNeverProbed() {
        var gesture = BrowserSwipeGesture()
        let before = gesture.generation
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0, takenByLayout: true) == .none)
        #expect(gesture.phase == .declined)
        for _ in 0..<4 { #expect(gesture.scroll(.changed, deltaX: 4, deltaY: 0) == .none) }
        #expect(gesture.phase == .declined, "declined until the gesture ends")
        #expect(gesture.generation > before, "a late answer of an earlier gesture's probe is ignored")
    }

    /// The layout's monitor decided nothing yet at `began` (no touch came first): the page is probed as
    /// before, and the first moving event the layout took declines it.
    @Test func aGestureTheLayoutTakesAfterItBeganIsDeclinedWhenItMoves() {
        var gesture = BrowserSwipeGesture()
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0) == .probe)
        for _ in 0..<4 { #expect(gesture.scroll(.changed, deltaX: 4, deltaY: 0, takenByLayout: true) == .none) }
        #expect(gesture.phase == .declined)
    }

    @Test func aLateAnswerOfAnEarlierGestureIsIgnored() {
        var (gesture, _) = gesture(dx: 3)
        let stale = gesture.generation
        _ = gesture.scroll(.ended, deltaX: 0, deltaY: 0)
        _ = gesture.scroll(.began, deltaX: 0, deltaY: 0)
        gesture.probeAnswered(Self.atEdges, generation: stale)
        #expect(gesture.phase == .pending)
    }

    @Test func theFirstProbesLateAnswerDoesNotConfirm() {
        // Crossed `slop` before the first probe answered: the first answer (the carousel's listener
        // only just installed) must not stand in for the confirming one.
        var gesture = BrowserSwipeGesture()
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0) == .probe)
        let first = gesture.generation
        _ = gesture.scroll(.changed, deltaX: 4, deltaY: 0)
        #expect(gesture.scroll(.changed, deltaX: 4, deltaY: 0) == .probe)
        #expect(gesture.phase == .confirming(.back))
        gesture.probeAnswered(Self.atEdges, generation: first)
        #expect(gesture.phase == .confirming(.back))
        #expect(gesture.scroll(.changed, deltaX: 4, deltaY: 0) == .none)
        gesture.probeAnswered(BrowserSwipeEdges(canScrollLeft: false, canScrollRight: false, consumesHorizontal: true),
                              generation: gesture.generation)
        #expect(gesture.phase == .declined)
    }

    @Test func aFrameThePageCannotReadKeepsTheGesture() {
        let script = BrowserSwipeProbe().script(x: 10, y: 10)
        #expect(script.contains("tag !== 'IFRAME'"))
        #expect(script.contains("left = true; right = true"))
    }

    @Test func theProbeAnswerParsesOnlyItsOwnShape() {
        #expect(BrowserSwipeProbe().edges(.array([.bool(true), .bool(false), .bool(false)]))
            == BrowserSwipeEdges(canScrollLeft: true, canScrollRight: false, consumesHorizontal: false))
        #expect(BrowserSwipeProbe().edges(.array([.bool(true), .bool(false)])) == nil)
        #expect(BrowserSwipeProbe().edges(.string("[true,false,false]")) == nil)
        #expect(BrowserSwipeProbe().script(x: .nan, y: 10).contains("scan(window, 0.0, 10.0, 0)"))
    }

    @MainActor @Test func theIndicatorSlidesInFromTheEdgeItPointsTo() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = BrowserSwipeIndicator.size
        let out = BrowserSwipeIndicator.frame(in: bounds, direction: .back, progress: 0)
        #expect(out.maxX == 0)
        #expect(out.midY == 300)
        let backIn = BrowserSwipeIndicator.frame(in: bounds, direction: .back, progress: 1)
        #expect(backIn.minX == BrowserSwipeIndicator.inset)
        let forwardIn = BrowserSwipeIndicator.frame(in: bounds, direction: .forward, progress: 1)
        #expect(forwardIn.maxX == 800 - BrowserSwipeIndicator.inset)
        #expect(forwardIn.width == size.width)
        #expect(BrowserSwipeIndicator.frame(in: bounds, direction: .forward, progress: 3) == forwardIn)
        #expect(BrowserSwipeIndicator.progress(amount: -BrowserSwipeIndicator.fullAmount / 2) == 0.5)
        #expect(BrowserSwipeIndicator.progress(amount: 0.9) == 1)
    }
}
