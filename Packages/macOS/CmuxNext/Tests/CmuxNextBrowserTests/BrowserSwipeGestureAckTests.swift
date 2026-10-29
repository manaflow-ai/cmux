import CoreGraphics
@testable import CmuxNextBrowser
import Testing

/// A swipe over a hosted page decides from Chromium's acks of the gesture's own wheels (WHEEL_ACK),
/// as Chrome's history swiper does: no probe is asked, a page whose first scroll update
/// scrolled anything (or whose script took a wheel) keeps the gesture, and a swipe needs an overscroll the
/// page leaves to the browser.
@Suite struct BrowserSwipeGestureAckTests {
    /// A page with no room that way: the update scrolled nothing and overscrolled, behavior auto.
    static func unconsumed(seq: UInt32 = 1, behavior: BrowserWheelAck.OverscrollBehavior = .auto) -> BrowserWheelAck {
        BrowserWheelAck(seq: seq, scrollUpdate: true, consumed: false, overscroll: .init(x: -4, behaviorX: behavior))
    }

    /// A page that scrolled sideways for the wheel.
    static func consumed(seq: UInt32 = 1) -> BrowserWheelAck {
        BrowserWheelAck(seq: seq, scrollUpdate: true, consumed: true, consumedX: 4)
    }

    /// Began with acks, then `steps` sideways events of `dx`.
    private func gesture(dx: CGFloat, steps: Int = 2) -> (BrowserSwipeGesture, [BrowserSwipeGesture.Step]) {
        var gesture = BrowserSwipeGesture()
        var out = [gesture.scroll(.began, deltaX: 0, deltaY: 0, pageAcks: true)]
        for _ in 0..<steps { out.append(gesture.scroll(.changed, deltaX: dx, deltaY: 0, pageAcks: true)) }
        return (gesture, out)
    }

    @Test func aGestureWithAcksAsksNoProbe() {
        let (gesture, steps) = gesture(dx: 3, steps: 2)
        #expect(steps == [.none, .none, .none], "no probe on began or past the slop")
        #expect(gesture.phase == .confirming(.back), "past the slop it waits for the acks")
    }

    @Test func aPageThatDoesNotScrollSidewaysSwipesOnceItOverscrolls() {
        var (gesture, _) = gesture(dx: 3)
        gesture.wheelAcked(Self.unconsumed())
        #expect(gesture.phase == .ready(.back))
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .track(.back))
    }

    @Test func acksBeforeTheSlopStartTheSwipeAtTheSlop() {
        var gesture = BrowserSwipeGesture()
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0, pageAcks: true) == .none)
        gesture.wheelAcked(Self.unconsumed())
        #expect(gesture.phase == .pending)
        #expect(gesture.scroll(.changed, deltaX: -3, deltaY: 0) == .none)
        #expect(gesture.scroll(.changed, deltaX: -3, deltaY: 0) == .track(.forward), "both answers are in: the slop event tracks")
    }

    @Test func aPageThatScrollsSidewaysKeepsTheGesture() {
        var (gesture, _) = gesture(dx: 3)
        gesture.wheelAcked(Self.consumed())
        #expect(gesture.phase == .declined)
        // A later overscroll at the scroller's edge does not hand this gesture over: only the first update counts.
        gesture.wheelAcked(Self.unconsumed(seq: 2))
        #expect(gesture.phase == .declined)
        #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .none)
    }

    @Test func aScriptThatTookTheWheelKeepsTheGesture() {
        var (gesture, _) = gesture(dx: 3)
        gesture.wheelAcked(BrowserWheelAck(seq: 1, scrollUpdate: false, consumed: true))
        #expect(gesture.phase == .declined)
    }

    @Test func anOverscrollThePageContainsIsNoSwipe() {
        for behavior in [BrowserWheelAck.OverscrollBehavior.contain, .disabled] {
            var (gesture, _) = gesture(dx: 3)
            gesture.wheelAcked(Self.unconsumed(behavior: behavior))
            #expect(gesture.phase == .confirming(.back), "overscroll-behavior-x \(behavior) keeps the swipe waiting")
            #expect(gesture.scroll(.changed, deltaX: 3, deltaY: 0) == .none)
        }
    }

    @Test func anUnconsumedUpdateWithoutOverscrollWaits() {
        var (gesture, _) = gesture(dx: 3)
        gesture.wheelAcked(BrowserWheelAck(seq: 1, scrollUpdate: true, consumed: false))
        #expect(gesture.phase == .confirming(.back))
        gesture.wheelAcked(Self.unconsumed(seq: 2))
        #expect(gesture.phase == .ready(.back), "the overscroll of a later wheel lets it go")
    }

    @Test func anAckThatSaysNothingDecidesNothing() {
        var (gesture, _) = gesture(dx: 3)
        // A phase edge with no delta: no update, nothing consumed.
        gesture.wheelAcked(BrowserWheelAck(seq: 1, scrollUpdate: false, consumed: false))
        #expect(gesture.phase == .confirming(.back))
        gesture.wheelAcked(Self.unconsumed(seq: 2))
        #expect(gesture.phase == .ready(.back))
    }

    @Test func probeAnswersAndAcksDoNotMix() {
        var (acked, _) = gesture(dx: 3)
        acked.probeAnswered(BrowserSwipeEdges(canScrollLeft: false, canScrollRight: false, consumesHorizontal: false),
                            generation: acked.generation)
        #expect(acked.phase == .confirming(.back), "a gesture with acks ignores probe answers")

        var probed = BrowserSwipeGesture()
        #expect(probed.scroll(.began, deltaX: 0, deltaY: 0) == .probe)
        probed.wheelAcked(Self.unconsumed())
        #expect(probed.phase == .pending, "a probing gesture ignores acks")
    }

    @Test func acksAfterTheGestureEndedDoNothing() {
        var (gesture, _) = gesture(dx: 3)
        #expect(gesture.scroll(.ended, deltaX: 0, deltaY: 0) == .none)
        gesture.wheelAcked(Self.unconsumed())
        #expect(gesture.phase == .idle)
    }

    @Test func aLayoutGestureIsNeverASwipe() {
        var gesture = BrowserSwipeGesture()
        #expect(gesture.scroll(.began, deltaX: 0, deltaY: 0, takenByLayout: true, pageAcks: true) == .none)
        gesture.wheelAcked(Self.unconsumed())
        #expect(gesture.phase == .declined)
    }

    @Test func theEventFieldsDecode() {
        // b: update | overscrolled, behavior contain (1 << 8), overscroll x -12.34 DIPs in the high 32 bits.
        let b = Int64(Int32(-1234)) << 32 | (1 << 8) | 0b101
        let a = Int64(Int32(-350)) << 32 | Int64(UInt32(bitPattern: 450))
        let ack = BrowserWheelAck(request: Int32(bitPattern: 0xFFFF_FFF0), a: a, b: b)
        #expect(ack.seq == 0xFFFF_FFF0)
        #expect(ack.scrollUpdate && !ack.consumed)
        #expect(ack.consumedX == 4.5 && ack.consumedY == -3.5)
        #expect(ack.overscroll == .init(x: -12.34, behaviorX: .contain))

        let plain = BrowserWheelAck(request: 7, a: 0, b: 0b010 | Int64(Int32(55)) << 32)
        #expect(plain.consumed && !plain.scrollUpdate)
        #expect(plain.overscroll == nil, "no overscrolled bit: the high bits are not read")

        let unknown = BrowserWheelAck(request: 7, a: 0, b: 0b100 | (3 << 8))
        #expect(unknown.overscroll?.behaviorX == .disabled, "an unknown behavior keeps the overscroll")
    }

    @Test func theShimEventIsAPageViewEvent() {
        let event = CEFShimEvent(kind: 56, browser: 9, request: 3, a: 0, b: 0b101, s1: "", s2: "")
        #expect(event == .pageView(browser: 9, .wheelAck(BrowserWheelAck(seq: 3, scrollUpdate: true, consumed: false,
                                                                          overscroll: .init(x: 0, behaviorX: .auto)))))
    }
}
