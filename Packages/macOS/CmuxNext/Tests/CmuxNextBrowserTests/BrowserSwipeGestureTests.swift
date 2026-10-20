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

    @Test func aLateAnswerOfAnEarlierGestureIsIgnored() {
        var (gesture, _) = gesture(dx: 3)
        let stale = gesture.generation
        _ = gesture.scroll(.ended, deltaX: 0, deltaY: 0)
        _ = gesture.scroll(.began, deltaX: 0, deltaY: 0)
        gesture.probeAnswered(Self.atEdges, generation: stale)
        #expect(gesture.phase == .pending)
    }

    @Test func theProbeAnswerParsesOnlyItsOwnShape() {
        #expect(BrowserSwipeProbe.edges(.array([.bool(true), .bool(false), .bool(false)]))
            == BrowserSwipeEdges(canScrollLeft: true, canScrollRight: false, consumesHorizontal: false))
        #expect(BrowserSwipeProbe.edges(.array([.bool(true), .bool(false)])) == nil)
        #expect(BrowserSwipeProbe.edges(.string("[true,false,false]")) == nil)
        #expect(BrowserSwipeProbe.script(x: .nan, y: 10).contains("elementFromPoint(0.0, 10.0)"))
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
