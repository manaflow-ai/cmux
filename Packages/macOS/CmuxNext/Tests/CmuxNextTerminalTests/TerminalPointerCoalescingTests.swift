import AppKit
import CmuxNextCompat
import CmuxNextInputCore
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import GhosttyNextKit
import Testing

/// A terminal's pointer input at most twice per frame (feature `terminalPointerFrames`;
/// Chromium's rAF-aligned input, `main_thread_event_queue.cc`): a counting surface sees moves and drags
/// as one `mouse_pos` on a frame interval's first event and one at the frame, at the latest point; a
/// button sends the latest position before itself; a mouse-reporting trackpad scroll is one
/// `mouse_scroll` per frame and phase, summed; a scrollback scroll and a wheel's lines go at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalPointerCoalescingTests {
    /// What reached Ghostty, in order.
    final class CountingMouse: TerminalMouseSink {
        private(set) var calls: [String] = []

        var positions: Int { calls.count(where: { $0.hasPrefix("pos") }) }
        var scrolls: [String] { calls.filter { $0.hasPrefix("scroll") } }

        func position(x: Double, y: Double, mods: ghostty_input_mods_e) {
            calls.append("pos \(Int(x)),\(Int(y))")
        }

        func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
            calls.append(state.rawValue == GHOSTTY_MOUSE_PRESS.rawValue ? "press" : "release")
            return false
        }

        func scroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
            calls.append("scroll \(Int(x)),\(Int(y))")
        }

        func pressure(stage: UInt32, pressure: Double) {
            calls.append("pressure \(stage)")
        }

        func clear() { calls.removeAll() }
    }

    /// A terminal session on scripted IO in a window, its surface replaced by a ``CountingMouse``, on a
    /// window coalescer whose fake link ticks only when the test calls ``frame()``.
    final class Harness {
        let io: ScriptedTerminalIO
        let session: TerminalSession
        let window: NSWindow
        let mouse: CountingMouse
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        private var frames = 0

        /// `coalesced`: the feature on. `programHasMouse`: the program turned mouse reporting on.
        init(coalesced: Bool = true, programHasMouse: Bool = false) {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            let ledger = WakeupLedger()
            let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in TestLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
            let coalescers = FrameInputCoalescers { _ in coalescer }
            let io = ScriptedTerminalIO()
            let session = TerminalSession(io: io, pointerFrames: coalesced ? coalescers : nil,
                                          mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
            let mouse = CountingMouse()
            session.surfaceView.mouse = mouse
            session.surfaceView.mouseCapture = TerminalMouseCapture(lane: nil, captured: programHasMouse)
            (self.scheduler, self.coalescer, self.io, self.session, self.window, self.mouse) = (scheduler, coalescer, io, session, window, mouse)
        }

        var view: TerminalSurfaceView { session.surfaceView }

        /// One 120 Hz link frame: the coalescer's trailing deliveries run.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        /// A window point inside the terminal, `step` points right of the first.
        func point(_ step: Int) -> NSPoint {
            let origin = view.convert(NSPoint(x: 20, y: 20), to: nil)
            return NSPoint(x: origin.x + CGFloat(step), y: origin.y)
        }

        /// What the counting surface gets for a pointer at window point `point`.
        func expected(_ point: NSPoint) -> String {
            let local = view.convert(point, from: nil)
            return "pos \(Int(local.x)),\(Int(view.bounds.height - local.y))"
        }

        func mouseEvent(_ type: NSEvent.EventType, _ point: NSPoint, at time: TimeInterval = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }

        /// A scroll over the terminal: pixel (trackpad) deltas unless `units` says lines.
        func scrollEvent(dy: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil,
                         units: CGScrollEventUnit = .pixel) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            if let momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: units == .pixel ? 1 : 0)
            return NSEvent(cgEvent: cg)!
        }

        /// A trackpad swipe: began, four changes, ended; returns its events.
        func swipe() -> [NSEvent] {
            [scrollEvent(dy: 1, phase: .began)] + ([2, 3, 4, 5] as [Int32]).map { scrollEvent(dy: $0, phase: .changed) }
                + [scrollEvent(dy: 0, phase: .ended)]
        }

        func close() {
            coalescer.invalidate()
            window.contentView = nil
            window.close()
            io.finish()
            session.close()
        }
    }

    // MARK: Moves and drags

    /// N moves in a frame: the first reaches Ghostty at once, the rest once at the frame, at the latest point.
    @Test func movesInAFrameReachGhosttyAtMostTwice() {
        let harness = Harness()
        defer { harness.close() }
        let points = (0..<8).map(harness.point)
        for point in points { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, point)) }
        #expect(harness.mouse.calls == [harness.expected(points[0])], "only the leading move before the frame")
        harness.frame()
        #expect(harness.mouse.calls == [harness.expected(points[0]), harness.expected(points[7])],
                "eight moves made \(harness.mouse.positions) mouse_pos calls")
        #expect(harness.view.pointerFrames?.maxDeliveriesPerFrame == 2)
        #expect(harness.view.pointerFrames?.hasPending == false)
    }

    /// A press after fast moves sends the latest move's position, then its own, then the press.
    @Test func aButtonAfterMovesSendsTheLatestPositionThenThePress() {
        let harness = Harness()
        defer { harness.close() }
        let points = (0..<5).map(harness.point)
        for point in points { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, point)) }
        let press = harness.point(40)
        harness.view.mouseDown(with: harness.mouseEvent(.leftMouseDown, press))
        #expect(harness.mouse.calls == [harness.expected(points[0]), harness.expected(points[4]), harness.expected(press), "press"])
        #expect(harness.view.pointerFrames?.hasPending == false)
        harness.frame()
        #expect(harness.mouse.calls.count == 4, "the flushed moves do not go again at the frame")
    }

    /// A flush ends the view's frame interval: the first move after a button is a leading edge again.
    @Test func aMoveAfterAFlushGoesAtOnce() {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<3 { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, harness.point(step))) }
        harness.view.otherMouseDown(with: harness.mouseEvent(.otherMouseDown, harness.point(3)))
        harness.mouse.clear()
        let after = harness.point(10)
        harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, after))
        #expect(harness.mouse.calls == [harness.expected(after)], "the move after the flush reached Ghostty in its own turn")
        #expect(harness.view.pointerFrames?.hasPending == false)
        harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, harness.point(11)))
        #expect(harness.view.pointerFrames?.hasPending == true, "the next one waits for the frame")
        harness.frame()
        #expect(harness.view.pointerFrames?.maxDeliveriesPerFrame == 2)
    }

    /// A force-touch pressure lands the latest drag point first: Ghostty applies it at its last position.
    @Test func pressureSendsTheLatestDragPointFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.mouseDown(with: harness.mouseEvent(.leftMouseDown, harness.point(0)))
        harness.mouse.clear()
        let drags = (1...5).map(harness.point)
        for point in drags { harness.view.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, point)) }
        harness.view.sendPressure(stage: 1, pressure: 0.5)
        #expect(harness.mouse.calls == [harness.expected(drags[0]), harness.expected(drags[4]), "pressure 1"])
        #expect(harness.view.pointerFrames?.hasPending == false)
    }

    /// Drags coalesce like moves, and the release lands the last drag point before the release.
    @Test func theReleaseLandsTheLastDragPointFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.mouseDown(with: harness.mouseEvent(.leftMouseDown, harness.point(0)))
        harness.mouse.clear()
        let drags = (1...6).map(harness.point)
        for point in drags { harness.view.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, point)) }
        #expect(harness.mouse.calls == [harness.expected(drags[0])], "only the leading drag before the release")
        let release = harness.point(6)
        harness.view.mouseUp(with: harness.mouseEvent(.leftMouseUp, release))
        #expect(harness.mouse.calls == [harness.expected(drags[0]), harness.expected(drags[5]), harness.expected(release), "release",
                                        "pressure 0"])
    }

    /// The feature off: every move reaches Ghostty at once, as before.
    @Test func withoutTheFeatureEveryMoveGoesAtOnce() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        let points = (0..<8).map(harness.point)
        for point in points { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, point)) }
        #expect(harness.mouse.calls == points.map(harness.expected))
        #expect(harness.view.pointerFrames == nil)
    }

    /// A terminal that leaves its window drops what waits: those points are the old window's.
    @Test func leavingTheWindowDropsPendingMoves() {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<3 { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, harness.point(step))) }
        #expect(harness.view.pointerFrames?.hasPending == true)
        harness.window.contentView = nil
        harness.frame()
        #expect(harness.mouse.positions == 1, "only the leading move reached Ghostty")
        #expect(harness.view.pointerFrames?.hasPending == false)
    }

    // MARK: Scroll

    /// While the program has the mouse, a trackpad swipe is one mouse_scroll per frame and phase: the
    /// began at once, then the summed changes and the ended at the frame, with the same total distance.
    @Test func aMouseReportingScrollIsOneCallPerFrameAndPhase() {
        let harness = Harness(programHasMouse: true)
        defer { harness.close() }
        let events = harness.swipe()
        for event in events { harness.view.scrollWheel(with: event) }
        #expect(harness.mouse.scrolls.count == 1, "only the began before the frame: \(harness.mouse.scrolls)")
        harness.frame()
        let total = events.reduce(0) { $0 + Int($1.scrollingDeltaY * 2) }
        let changes = events[1...4].reduce(0) { $0 + Int($1.scrollingDeltaY * 2) }
        #expect(harness.mouse.scrolls == ["scroll 0,\(Int(events[0].scrollingDeltaY * 2))", "scroll 0,\(changes)",
                                          "scroll 0,\(Int(events[5].scrollingDeltaY * 2))"])
        let sent = harness.mouse.scrolls.reduce(0) { $0 + Int($1.split(separator: ",")[1])! }
        #expect(sent == total, "the summed scroll keeps the distance")
    }

    /// A scroll through the scrollback reaches Ghostty at once, per event, the same calls as with the feature off.
    @Test func aScrollbackScrollIsUnchanged() {
        let coalesced = Harness()
        defer { coalesced.close() }
        let perEvent = Harness(coalesced: false)
        defer { perEvent.close() }
        for harness in [coalesced, perEvent] {
            for event in harness.swipe() { harness.view.scrollWheel(with: event) }
        }
        #expect(coalesced.mouse.scrolls.count == 6, "every scrollback event went at once")
        #expect(coalesced.mouse.calls == perEvent.mouse.calls)
        #expect(coalesced.view.pointerFrames?.hasPending == false)
    }

    /// A wheel's line scroll goes at once even while the program has the mouse: Ghostty counts each notch.
    @Test func aWheelsLinesGoAtOnce() {
        let harness = Harness(programHasMouse: true)
        defer { harness.close() }
        for _ in 0..<4 { harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, units: .line)) }
        #expect(harness.mouse.scrolls.count == 4)
        #expect(harness.view.pointerFrames?.hasPending == false)
    }

    /// A scroll that goes at once sends the moves waiting before it first.
    @Test func aScrollThatGoesAtOnceSendsPendingMovesFirst() {
        let harness = Harness()
        defer { harness.close() }
        let points = (0..<3).map(harness.point)
        for point in points { harness.view.mouseMoved(with: harness.mouseEvent(.mouseMoved, point)) }
        let scroll = harness.scrollEvent(dy: 3, phase: .began)
        harness.view.scrollWheel(with: scroll)
        #expect(harness.mouse.calls == [harness.expected(points[0]), harness.expected(points[2]),
                                        "scroll 0,\(Int(scroll.scrollingDeltaY * 2))"])
    }
}

/// Whether a terminal scroll waits for the frame follows ``TerminalMouseCapture``'s answers: a gesture's
/// first event (or a phaseless one) asks once behind the output, the answer turns coalescing on or off for
/// the events after it, and an ask still on the lane is not queued again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalMouseCaptureTests {
    typealias Harness = TerminalPointerCoalescingTests.Harness

    /// The output lane's side: it holds the asks until the test answers them.
    final class FakeCaptureLane: Sendable {
        private let waiting = Mutex<[@Sendable (Bool) -> Void]>([])
        private let made = Mutex(0)

        var asks: Int { made.withLock { $0 } }

        var ask: TerminalMouseCapture.Ask {
            { [self] answer in
                made.withLock { $0 += 1 }
                waiting.withLock { $0.append(answer) }
            }
        }

        /// The lane parsed the output queued before the asks: the program has the mouse or not.
        func answer(_ hasMouse: Bool) {
            let answers = waiting.withLock { pending in
                let taken = pending
                pending.removeAll()
                return taken
            }
            for answer in answers { answer(hasMouse) }
        }
    }

    private func fakeLane(on harness: Harness) -> FakeCaptureLane {
        let lane = FakeCaptureLane()
        harness.view.mouseCapture = TerminalMouseCapture(ask: lane.ask)
        return lane
    }

    /// A began asks; its changes, its ended and the momentum after it do not; a phaseless scroll asks.
    @Test func onlyAGesturesFirstEventAsks() {
        let harness = Harness()
        defer { harness.close() }
        let lane = fakeLane(on: harness)
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        #expect(lane.asks == 1)
        lane.answer(false)
        for dy: Int32 in [2, 3] { harness.view.scrollWheel(with: harness.scrollEvent(dy: dy, phase: .changed)) }
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 0, phase: .ended))
        for dy: Int32 in [4, 2] { harness.view.scrollWheel(with: harness.scrollEvent(dy: dy, momentum: .continuous)) }
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 0, momentum: .end))
        #expect(lane.asks == 1, "changes, the end and momentum keep the gesture's answer")
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 3))
        #expect(lane.asks == 2, "a phaseless scroll is its own gesture")
    }

    /// While an ask is on the lane a second gesture does not queue another; after the answer one does.
    @Test func aPendingAskIsNotQueuedTwice() {
        let harness = Harness()
        defer { harness.close() }
        let lane = fakeLane(on: harness)
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 0, phase: .ended))
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        #expect(lane.asks == 1, "the first ask still waits behind the output")
        lane.answer(false)
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        #expect(lane.asks == 2)
    }

    /// The answer decides the next events: yes coalesces a gesture's changes to the frame, no sends each at once.
    @Test func theAnswerTurnsCoalescingOnAndOff() {
        let harness = Harness()
        defer { harness.close() }
        let lane = fakeLane(on: harness)
        let changes: [Int32] = [2, 3, 4]

        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        #expect(harness.mouse.scrolls.count == 1, "no answer yet: the began went at once, as a scrollback scroll")
        lane.answer(true)
        for dy in changes { harness.view.scrollWheel(with: harness.scrollEvent(dy: dy, phase: .changed)) }
        #expect(harness.mouse.scrolls.count == 2, "the program has the mouse: the leading change went, the rest wait")
        #expect(harness.view.pointerFrames?.hasPending == true)
        harness.view.scrollWheel(with: harness.scrollEvent(dy: 0, phase: .ended))
        harness.frame()
        #expect(harness.view.pointerFrames?.hasPending == false)
        harness.mouse.clear()

        harness.view.scrollWheel(with: harness.scrollEvent(dy: 1, phase: .began))
        #expect(lane.asks == 2)
        lane.answer(false)
        for dy in changes { harness.view.scrollWheel(with: harness.scrollEvent(dy: dy, phase: .changed)) }
        #expect(harness.mouse.scrolls.count == 1 + changes.count, "the program let go of the mouse: every change at once")
        #expect(harness.view.pointerFrames?.hasPending == false)
    }
}

@MainActor
private final class TestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// A coalesced scroll's momentum: what Ghostty gets for one event of the same phase.
@MainActor @Suite struct TerminalScrollMomentumTests {
    @Test func aMomentumRunGoesAsItsChangesAndItsEndAsTheEnd() {
        #expect(TerminalSurfaceView.momentum(.momentum) == TerminalSurfaceView.momentum(NSEvent.Phase.changed))
        #expect(TerminalSurfaceView.momentum(.momentumEnded) == TerminalSurfaceView.momentum(NSEvent.Phase.ended))
        for phase: InputScrollPhase in [.none, .mayBegin, .began, .changed, .ended, .cancelled] {
            #expect(TerminalSurfaceView.momentum(phase) == TerminalSurfaceView.momentum(NSEvent.Phase()), "fingers down: no momentum")
        }
        #expect(TerminalSurfaceView.scrollMods(precise: true, momentum: TerminalSurfaceView.momentum(NSEvent.Phase.changed))
                == TerminalSurfaceView.scrollMods(precise: true, phase: .changed))
    }
}
