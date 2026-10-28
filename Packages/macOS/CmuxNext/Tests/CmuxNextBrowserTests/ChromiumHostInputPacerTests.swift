#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// Ack-based pacing of a hosted page's input: the first move or wheel tick
/// leaves at once, later ones wait coalesced (latest move, wheel deltas summed per phase) and
/// leave on the host's ack, at most one of each in flight; keys and clicks never wait, and what
/// waited leaves ahead of them in arrival order.
@MainActor
@Suite struct ChromiumHostInputPacerTests {
    static func move(_ x: Int32, buttons: Int32 = 0) -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [x, 0, 0, 0, 0, buttons])
    }

    static func click(_ phase: Int32, x: Int32 = 0) -> ChromiumHostFrame {
        ChromiumHostFrame(.mouse, v: [x, 0, phase, 0, 1, 1])
    }

    static func key(_ code: Int32) -> ChromiumHostFrame {
        ChromiumHostFrame(.key, v: [0, code])
    }

    /// A wheel tick (p04-input-063's wire): dy, scroll phase and momentum phase as `NSEvent.Phase`
    /// bits (1 began, 4 changed, 8 ended), precise (trackpad, ``ChromiumHostFrame/wheelPrecise``) by default.
    static func wheel(dy: Int32, phase: Int32 = 4, momentum: Int32 = 0, precise: Bool = true,
                      flags: UInt64 = 0) -> ChromiumHostFrame {
        ChromiumHostFrame(.wheel, v: [5, 6, 0, dy, phase, momentum],
                          flags: flags | (precise ? ChromiumHostFrame.wheelPrecise : 0))
    }

    /// Everything `submit` releases, in send order.
    static func sent(_ release: ChromiumHostInputPacer.Release) -> [ChromiumHostFrame] {
        release.ahead + (release.frame.map { [$0] } ?? [])
    }

    @Test func theFirstMoveAndWheelTickLeaveAtOnce() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)) == .init(frame: Self.move(1)))
        #expect(pacer.submit(Self.wheel(dy: -3, phase: 1)) == .init(frame: Self.wheel(dy: -3, phase: 1)))
        #expect(pacer.movesInFlight == 1 && pacer.wheelsInFlight == 1)
        #expect(pacer.stats.sent == 2)
    }

    @Test func movesBehindAnUnackedMoveCoalesceToTheLatestAndLeaveOnTheAck() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        for x in Int32(2)...100 { #expect(Self.sent(pacer.submit(Self.move(x, buttons: x == 100 ? 1 : 0))).isEmpty) }
        #expect(pacer.waitingCount == 1)
        #expect(pacer.stats.coalesced == 98)
        #expect(pacer.acked(.move) == Self.move(100, buttons: 1))
        #expect(pacer.movesInFlight == 1)
        #expect(pacer.acked(.move) == nil)
        #expect(pacer.movesInFlight == 0)
        #expect(pacer.submit(Self.move(101)) == .init(frame: Self.move(101)))  // nothing in flight: at once again
        #expect(pacer.stats.maxMovesInFlight == 1)
    }

    @Test func wheelTicksSumPerPhaseAndLeaveOneAtATime() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.wheel(dy: -1, phase: 1)).frame != nil)  // began
        for _ in 0..<4 { #expect(Self.sent(pacer.submit(Self.wheel(dy: -2))).isEmpty) }  // changed
        #expect(Self.sent(pacer.submit(Self.wheel(dy: 0, phase: 8))).isEmpty)  // ended
        for _ in 0..<3 { #expect(Self.sent(pacer.submit(Self.wheel(dy: -5, phase: 0, momentum: 4))).isEmpty) }
        #expect(Self.sent(pacer.submit(Self.wheel(dy: -1, phase: 0, momentum: 4, flags: 1 << 17))).isEmpty)  // other modifiers
        #expect(pacer.waitingCount == 4)
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -8))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: 0, phase: 8))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -15, phase: 0, momentum: 4))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -1, phase: 0, momentum: 4, flags: 1 << 17))
        #expect(pacer.acked(.wheel) == nil)
        #expect(pacer.wheelsInFlight == 0)
        #expect(pacer.stats.maxWheelsInFlight == 1)
        #expect(pacer.stats.sent == 5)
    }

    @Test func coarseAndPreciseTicksDoNotFoldAndDeltasSaturate() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.wheel(dy: 1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.wheel(dy: .max))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.wheel(dy: .max))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.wheel(dy: 4, precise: false))).isEmpty)
        #expect(pacer.acked(.wheel) == Self.wheel(dy: .max))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: 4, precise: false))
    }

    /// The last move of a drag reaches the page before the mouse-up, never after it or not at all
    /// (Blink's MainThreadEventQueue dispatches the coalesced move ahead of the discrete event).
    @Test func aClickSendsTheWaitingMoveFirstThenItself() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1, buttons: 1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.move(2, buttons: 1))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.move(3, buttons: 1))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.click(2, x: 3))) == [Self.move(3, buttons: 1), Self.click(2, x: 3)])
        #expect(pacer.waitingCount == 0)
        #expect(pacer.stats.flushedAhead == 1)
        #expect(pacer.movesInFlight == 2)  // the first move and the flushed one, both unacked
        #expect(pacer.acked(.move) == nil)
        #expect(pacer.acked(.move) == nil)
        #expect(pacer.movesInFlight == 0)
    }

    @Test func aKeySendsTheWaitingMoveFirstThenItself() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.move(2))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.key(36))) == [Self.move(2), Self.key(36)])
        #expect(Self.sent(pacer.submit(Self.key(37))) == [Self.key(37)])  // nothing waits: the key alone
        let focus = ChromiumHostFrame(.focus, v: [1])
        #expect(pacer.submit(focus) == .init(frame: focus))
    }

    @Test func aFlushKeepsTheMoveAndTheWheelTicksInArrivalOrder() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        #expect(pacer.submit(Self.wheel(dy: 1, phase: 1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.wheel(dy: 2))).isEmpty)  // waits first
        #expect(Self.sent(pacer.submit(Self.move(2))).isEmpty)  // then the move
        #expect(Self.sent(pacer.submit(Self.wheel(dy: 3, phase: 8))).isEmpty)  // then another phase
        #expect(Self.sent(pacer.submit(Self.key(36)))
            == [Self.wheel(dy: 2), Self.move(2), Self.wheel(dy: 3, phase: 8), Self.key(36)])
        #expect(pacer.waitingCount == 0)
    }

    /// A full ring's backlog folds a flushed move into the one before it: the host acks only the
    /// newest, which settles both.
    @Test func anAckOfTheNewestMoveWrittenSettlesEveryEarlierOne() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        pacer.written(.move, seq: 10)
        #expect(Self.sent(pacer.submit(Self.move(2))).isEmpty)
        #expect(Self.sent(pacer.submit(Self.key(36))).count == 2)
        pacer.written(.move, seq: 11)
        #expect(pacer.movesInFlight == 2)
        #expect(Self.sent(pacer.submit(Self.move(3))).isEmpty)
        #expect(pacer.acked(.move, seq: 11) == Self.move(3))  // 10 never comes: folded into 11
        #expect(pacer.movesInFlight == 1)
    }

    @Test func anUnsentPacedFrameIsNoLongerInFlight() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        pacer.unsent(.move)  // the writer had no host: no ack will come
        #expect(pacer.movesInFlight == 0)
        #expect(pacer.submit(Self.move(2)) == .init(frame: Self.move(2)))
        #expect(pacer.stats.unsent == 1)
    }

    @Test func anAckWithNothingInFlightIsCountedAndSendsNothing() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.acked(.wheel) == nil)
        #expect(pacer.acked(.move) == nil)
        #expect(pacer.stats.unexpectedAcks == 2)
        #expect(pacer.movesInFlight == 0 && pacer.wheelsInFlight == 0)
    }

    @Test func aStoppedHostHoldsABoundedWheelQueue() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.wheel(dy: 1)).frame != nil)
        // Ticks that each differ from the last (other modifiers) never fold: the waiting queue stops at its limit.
        for index in 0..<(ChromiumHostInputPacer.waitingWheelLimit + 10) {
            #expect(Self.sent(pacer.submit(Self.wheel(dy: 1, flags: UInt64(index + 1)))).isEmpty)
        }
        #expect(pacer.waitingCount == ChromiumHostInputPacer.waitingWheelLimit)
        #expect(pacer.stats.dropped == 10)
    }

    @Test func resetForgetsWhatWasInFlightAndWaiting() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.move(2))).isEmpty)
        #expect(pacer.submit(Self.wheel(dy: 1)).frame != nil)
        #expect(Self.sent(pacer.submit(Self.wheel(dy: 1))).isEmpty)
        pacer.reset()
        #expect(pacer.waitingCount == 0 && pacer.movesInFlight == 0 && pacer.wheelsInFlight == 0)
        #expect(pacer.submit(Self.move(3)) == .init(frame: Self.move(3)))
    }

    // MARK: The page view

    func makePage() -> ChromiumHostPageView {
        ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                             makeLayerHost: { _ in CALayer() })
    }

    static func mouseEvent(_ type: NSEvent.EventType, at x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [],
                                        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
                                        clickCount: type == .leftMouseUp ? 1 : 0, pressure: 0))
    }

    static func mouseMoved(at x: CGFloat) throws -> NSEvent {
        try mouseEvent(.mouseMoved, at: x)
    }

    static let receipt = ChromiumHostInputReceipt(browser: 1, seq: 1)

    @Test func aPacedPageSendsOneMoveInFlightAndTheLatestOnTheAck() throws {
        let page = makePage()
        var sent: [ChromiumHostFrame] = []
        page.sink = { frame in
            sent.append(frame)
            return Self.receipt
        }
        page.pacesInput = true
        for x in 1...50 { page.mouseMoved(with: try Self.mouseMoved(at: CGFloat(x))) }
        #expect(sent.count == 1)
        #expect(sent.first?.v[0] == 1)
        page.inputAcked(.move)
        #expect(sent.count == 2)
        #expect(sent.last?.v[0] == 50)
        page.inputAcked(.move)
        #expect(sent.count == 2)
        #expect(page.inputPacer?.stats.maxMovesInFlight == 1)
    }

    @Test func aPacedDragSendsItsLastMoveBeforeTheMouseUp() throws {
        let page = makePage()
        var sent: [ChromiumHostFrame] = []
        page.sink = { frame in
            sent.append(frame)
            return Self.receipt
        }
        page.pacesInput = true
        for x in 1...10 { page.mouseDragged(with: try Self.mouseEvent(.leftMouseDragged, at: CGFloat(x))) }
        page.mouseUp(with: try Self.mouseEvent(.leftMouseUp, at: 10))
        #expect(sent.map { $0.v[2] } == [0, 0, 2])  // move, the last move, then the up
        #expect(sent.map { $0.v[0] } == [1, 10, 10])
    }

    @Test func aMoveTheWriterDidNotTakeDoesNotStallTheNext() throws {
        let page = makePage()
        var sent = 0
        page.sink = { _ in
            sent += 1
            return nil  // no host attached: nothing written, no ack
        }
        page.pacesInput = true
        for x in 1...5 { page.mouseMoved(with: try Self.mouseMoved(at: CGFloat(x))) }
        #expect(sent == 5)
        #expect(page.inputPacer?.movesInFlight == 0)
    }

    @Test func anUnpacedPageSendsEveryMove() throws {
        let page = makePage()
        var sent = 0
        page.sink = { _ in
            sent += 1
            return nil
        }
        for x in 1...50 { page.mouseMoved(with: try Self.mouseMoved(at: CGFloat(x))) }
        #expect(sent == 50)
        #expect(page.inputPacer == nil)
    }

    @Test func aSinkThatAcksAtOnceKeepsEveryMoveFlowing() throws {
        let page = makePage()
        var sent = 0
        page.sink = { [weak page] frame in
            sent += 1
            if ChromiumHostInputPacer.paced(frame) == .move { page?.inputAcked(.move) }
            return Self.receipt
        }
        page.pacesInput = true
        for x in 1...20 { page.mouseMoved(with: try Self.mouseMoved(at: CGFloat(x))) }
        #expect(sent == 20)
        #expect(page.inputPacer?.movesInFlight == 0)
    }
}
#endif
