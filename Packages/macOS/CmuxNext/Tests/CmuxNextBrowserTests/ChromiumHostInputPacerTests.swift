#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// Ack-based pacing of a hosted page's input (p01-process-042): the first move or wheel tick
/// leaves at once, later ones wait coalesced (latest move, wheel deltas summed per phase) and
/// leave on the host's ack, at most one of each in flight; keys and clicks never wait.
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

    /// A wheel tick: dy pixels, scroll phase, momentum phase, precise (trackpad) by default.
    static func wheel(dy: Int32, phase: Int32 = 3, momentum: Int32 = 0, precise: Bool = true,
                      flags: UInt64 = 0) -> ChromiumHostFrame {
        var frame = ChromiumHostFrame(.wheel, v: [5, 6, 0, dy, phase, momentum], flags: flags)
        frame.ch = precise ? 1 : 0
        return frame
    }

    @Test func theFirstMoveAndWheelTickLeaveAtOnce() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)) == Self.move(1))
        #expect(pacer.submit(Self.wheel(dy: -3, phase: 2)) == Self.wheel(dy: -3, phase: 2))
        #expect(pacer.movesInFlight == 1 && pacer.wheelsInFlight == 1)
        #expect(pacer.stats.sent == 2)
    }

    @Test func movesBehindAnUnackedMoveCoalesceToTheLatestAndLeaveOnTheAck() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)) != nil)
        for x in Int32(2)...100 { #expect(pacer.submit(Self.move(x, buttons: x == 100 ? 1 : 0)) == nil) }
        #expect(pacer.waitingCount == 1)
        #expect(pacer.stats.coalesced == 98)
        #expect(pacer.acked(.move) == Self.move(100, buttons: 1))
        #expect(pacer.movesInFlight == 1)
        #expect(pacer.acked(.move) == nil)
        #expect(pacer.movesInFlight == 0)
        #expect(pacer.submit(Self.move(101)) == Self.move(101))  // nothing in flight: at once again
        #expect(pacer.stats.maxMovesInFlight == 1)
    }

    @Test func wheelTicksSumPerPhaseAndLeaveOneAtATime() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.wheel(dy: -1, phase: 2)) != nil)  // began
        for _ in 0..<4 { #expect(pacer.submit(Self.wheel(dy: -2)) == nil) }  // changed
        #expect(pacer.submit(Self.wheel(dy: 0, phase: 4)) == nil)  // ended
        for _ in 0..<3 { #expect(pacer.submit(Self.wheel(dy: -5, phase: 0, momentum: 3)) == nil) }
        #expect(pacer.submit(Self.wheel(dy: -1, phase: 0, momentum: 3, flags: 1 << 17)) == nil)  // other modifiers
        #expect(pacer.waitingCount == 4)
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -8))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: 0, phase: 4))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -15, phase: 0, momentum: 3))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: -1, phase: 0, momentum: 3, flags: 1 << 17))
        #expect(pacer.acked(.wheel) == nil)
        #expect(pacer.wheelsInFlight == 0)
        #expect(pacer.stats.maxWheelsInFlight == 1)
        #expect(pacer.stats.sent == 5)
    }

    @Test func coarseAndPreciseTicksDoNotFoldAndDeltasSaturate() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.wheel(dy: 1)) != nil)
        #expect(pacer.submit(Self.wheel(dy: .max)) == nil)
        #expect(pacer.submit(Self.wheel(dy: .max)) == nil)
        #expect(pacer.submit(Self.wheel(dy: 4, precise: false)) == nil)
        #expect(pacer.acked(.wheel) == Self.wheel(dy: .max))
        #expect(pacer.acked(.wheel) == Self.wheel(dy: 4, precise: false))
    }

    @Test func keysAndClicksPassAtOnceAndAClickDropsTheStaleWaitingMove() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)) != nil)
        #expect(pacer.submit(Self.move(2)) == nil)
        #expect(pacer.submit(Self.key(36)) == Self.key(36))  // a key leaves the waiting move alone
        #expect(pacer.waitingCount == 1)
        #expect(pacer.submit(Self.click(1, x: 3)) == Self.click(1, x: 3))
        #expect(pacer.waitingCount == 0)
        #expect(pacer.stats.superseded == 1)
        #expect(pacer.submit(Self.click(2, x: 3)) == Self.click(2, x: 3))
        #expect(pacer.acked(.move) == nil)  // the dropped move never leaves after the click
        let focus = ChromiumHostFrame(.focus, v: [1])
        #expect(pacer.submit(focus) == focus)
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
        #expect(pacer.submit(Self.wheel(dy: 1)) != nil)
        // Ticks that each differ from the last (other modifiers) never fold: the waiting queue stops at its limit.
        for index in 0..<(ChromiumHostInputPacer.waitingWheelLimit + 10) {
            #expect(pacer.submit(Self.wheel(dy: 1, flags: UInt64(index + 1))) == nil)
        }
        #expect(pacer.waitingCount == ChromiumHostInputPacer.waitingWheelLimit)
        #expect(pacer.stats.dropped == 10)
    }

    @Test func resetForgetsWhatWasInFlightAndWaiting() {
        var pacer = ChromiumHostInputPacer()
        #expect(pacer.submit(Self.move(1)) != nil)
        #expect(pacer.submit(Self.move(2)) == nil)
        #expect(pacer.submit(Self.wheel(dy: 1)) != nil)
        #expect(pacer.submit(Self.wheel(dy: 1)) == nil)
        pacer.reset()
        #expect(pacer.waitingCount == 0 && pacer.movesInFlight == 0 && pacer.wheelsInFlight == 0)
        #expect(pacer.submit(Self.move(3)) == Self.move(3))
    }

    // MARK: The page view

    func makePage() -> ChromiumHostPageView {
        ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                             makeLayerHost: { _ in CALayer() })
    }

    static func mouseMoved(at x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 10), modifierFlags: [],
                                        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0,
                                        pressure: 0))
    }

    @Test func aPacedPageSendsOneMoveInFlightAndTheLatestOnTheAck() throws {
        let page = makePage()
        var sent: [ChromiumHostFrame] = []
        page.sink = { sent.append($0) }
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

    @Test func anUnpacedPageSendsEveryMove() throws {
        let page = makePage()
        var sent = 0
        page.sink = { _ in sent += 1 }
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
        }
        page.pacesInput = true
        for x in 1...20 { page.mouseMoved(with: try Self.mouseMoved(at: CGFloat(x))) }
        #expect(sent == 20)
        #expect(page.inputPacer?.movesInFlight == 0)
    }

    @Test func wheelPhasesMapToTheShimsValues() {
        #expect(ChromiumHostPageView.wheelPhase([]) == 0)
        #expect(ChromiumHostPageView.wheelPhase(.mayBegin) == 1)
        #expect(ChromiumHostPageView.wheelPhase(.began) == 2)
        #expect(ChromiumHostPageView.wheelPhase(.changed) == 3)
        #expect(ChromiumHostPageView.wheelPhase(.stationary) == 3)
        #expect(ChromiumHostPageView.wheelPhase(.ended) == 4)
        #expect(ChromiumHostPageView.wheelPhase(.cancelled) == 5)
    }
}
#endif
