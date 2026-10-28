import AppKit
@testable import CmuxNextRemoteView
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The remote desktop's pointer once per frame (feature `pointerFrameRemoteInput`): with
/// the window's FrameInputCoalescer a frame interval's first move goes to the host at
/// once and the rest once at the frame, to the latest point; scrolls in the middle of a gesture sum per
/// phase; a button, a key or a scroll phase edge sends what waits first (Chromium's rAF-aligned input
/// and `ShouldFlushQueue`, `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`).
@MainActor @Suite(.serialized) struct RemoteInputCaptureTests {
    final class Recorder: RemoteViewInputSink {
        var events: [RemoteInputEvent] = []
        func send(_ event: RemoteInputEvent) { events.append(event) }
        var pointers: [RemoteInputEvent] { events.filter { if case .pointer = $0 { true } else { false } } }
        var scrolls: [RemoteInputEvent] { events.filter { if case .scroll = $0 { true } else { false } } }
    }

    /// Control mode needs the key window; a test window never becomes key on its own.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    final class Harness {
        let capture = RemoteInputCaptureView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let sink = Recorder()
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        private var frames = 0

        /// `coalesced`: the pointer goes through the window's coalescer (the feature on). `controlMode`
        /// false: the view mode, where nothing goes to the host.
        init(coalesced: Bool = true, controlMode: Bool = true) {
            _ = NSApplication.shared
            let ledger = WakeupLedger()
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in RemoteCaptureTestLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
            self.coalescer = coalescer
            window = KeyWindow(contentRect: capture.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = capture
            capture.geometry = { RemoteViewGeometry(framePixels: CGSize(width: 1600, height: 1200), bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                    backingScale: 2) }
            capture.controller.sink = sink
            capture.pointerFrames = coalesced ? FrameInputCoalescers { _ in coalescer } : nil
            capture.controlMode = controlMode
            window.makeFirstResponder(capture)
        }

        /// A mouse-wheel notch of `lines`: no phase, no momentum, line deltas.
        func wheelNotch(lines: Int32 = 1) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!)!
        }

        func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 300) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// The stream pixel of window point (`x`, `y`), as the capture view maps it.
        func pixel(x: CGFloat, y: CGFloat = 300) -> RemoteInputEvent {
            let point = capture.convert(NSPoint(x: x, y: y), from: nil)
            let pixel = capture.geometry()!.clampedStreamPixel(at: point)
            return .pointer(x: pixel.x, y: pixel.y)
        }

        /// A trackpad scroll of `dy` points in `phase` (or momentum `momentum`).
        func scroll(dy: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return NSEvent(cgEvent: cg)!
        }

        /// One 120 Hz link frame: the coalescer's trailing deliveries run.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight moves in one frame: the first goes to the host at once, the other seven once at the frame.
    @Test func eightMovesInOneFrameSendTwoPointerMessages() {
        let harness = Harness()
        defer { harness.close() }
        for step in 1...8 {
            harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.sink.pointers == [harness.pixel(x: 110)], "the leading move went in its own turn")
        harness.frame()
        #expect(harness.sink.pointers == [harness.pixel(x: 110), harness.pixel(x: 180)], "the frame sent the latest point once")
        harness.frame()
        #expect(harness.sink.pointers.count == 2, "an idle frame sends nothing")
    }

    /// Without the coalescer (the feature off) every move goes at once.
    @Test func withoutTheCoalescerEveryMoveIsSent() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        for step in 1...8 {
            harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.sink.pointers.count == 8)
    }

    /// A press sends the waiting move first, then its own point and the button: the host sees the
    /// pointer arrive where the person clicked, in order.
    @Test func aPressSendsTheWaitingMoveFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 110))
        harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 120))
        harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 130))
        harness.capture.mouseDown(with: harness.mouse(.leftMouseDown, x: 130))
        #expect(harness.sink.events == [harness.pixel(x: 110), harness.pixel(x: 130), harness.pixel(x: 130), .button(.left, down: true)])
        #expect(!harness.coalescer.hasPending)
    }

    /// Drags merge like moves; the release sends the last drag point before the button goes up.
    @Test func theReleaseSendsTheLastDragPointFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.capture.mouseDown(with: harness.mouse(.leftMouseDown, x: 100))
        harness.frame()
        for step in 1...6 {
            harness.capture.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 100 + CGFloat(step) * 10))
        }
        harness.capture.mouseUp(with: harness.mouse(.leftMouseUp, x: 160))
        #expect(harness.sink.events == [harness.pixel(x: 100), .button(.left, down: true), harness.pixel(x: 110), harness.pixel(x: 160),
                                        .button(.left, down: false)])
    }

    /// A key sends the waiting move first.
    @Test func aModifierKeySendsTheWaitingMoveFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 110))
        harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 150))
        let shift = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                     windowNumber: harness.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 56)!
        harness.capture.flagsChanged(with: shift)
        #expect(Array(harness.sink.events.prefix(2)) == [harness.pixel(x: 110), harness.pixel(x: 150)])
        #expect(harness.sink.events.count == 3, "the shift key went after the moves")
    }

    /// Scrolls in the middle of a gesture sum per phase; its edges go at once, after what waits.
    @Test func midGestureScrollsSumPerPhase() {
        let harness = Harness()
        defer { harness.close() }
        harness.capture.scrollWheel(with: harness.scroll(dy: 0, phase: .began))
        for _ in 1...4 { harness.capture.scrollWheel(with: harness.scroll(dy: 3, phase: .changed)) }
        #expect(harness.sink.scrolls == [.scroll(dx: 0, dy: 300, precise: true)], "the leading scroll went in its own turn")
        harness.capture.scrollWheel(with: harness.scroll(dy: 0, phase: .ended))
        #expect(harness.sink.scrolls == [.scroll(dx: 0, dy: 300, precise: true), .scroll(dx: 0, dy: 900, precise: true)],
                "the end sent the three waiting scrolls as one, summed")
        harness.frame()
        harness.capture.scrollWheel(with: harness.scroll(dy: 0, momentum: .begin))
        for _ in 1...3 { harness.capture.scrollWheel(with: harness.scroll(dy: 2, momentum: .continuous)) }
        harness.frame()
        #expect(Array(harness.sink.scrolls.suffix(2)) == [.scroll(dx: 0, dy: 200, precise: true), .scroll(dx: 0, dy: 400, precise: true)],
                "momentum is its own phase: its first scroll at once, the rest summed at the frame")
        #expect(!harness.coalescer.hasPending)
    }

    /// Mouse-wheel notches have no phase and merge like a gesture's middle (Chromium merges wheels of
    /// equal phase, none included): eight in one frame reach the host twice, the second with the sum
    /// of the other seven, so a free-spinning wheel sends at most two scrolls per frame.
    @Test func eightWheelNotchesInOneFrameSendTwoScrolls() {
        let harness = Harness()
        defer { harness.close() }
        let notch = harness.wheelNotch()
        let lines = Double(notch.scrollingDeltaY)
        harness.capture.scrollWheel(with: notch)
        for _ in 1...7 { harness.capture.scrollWheel(with: harness.wheelNotch()) }
        #expect(harness.sink.scrolls.count == 1, "the leading notch went in its own turn")
        harness.frame()
        // The host's accumulator as the view drives it: the first notch, then the seven summed in order.
        var expected = RemoteScrollAccumulator()
        var sum = lines
        for _ in 2...7 { sum += lines }
        let sent = [expected.add(deltaX: 0, deltaY: lines, precise: false, phase: [], momentumPhase: []),
                    expected.add(deltaX: 0, deltaY: sum, precise: false, phase: [], momentumPhase: [])].compactMap { $0 }
        #expect(sent.count == 2)
        #expect(harness.sink.scrolls == sent, "the frame sent the seven waiting notches as one, summed")
        #expect(!harness.coalescer.hasPending)
    }

    /// In view mode nothing goes to the host, so moves and scrolls never reach the coalescer: hovering
    /// a passive remote desktop does not run the window's frame.
    @Test func aPassivePaneNeverWakesTheFrame() {
        let harness = Harness(controlMode: false)
        defer { harness.close() }
        for step in 1...8 {
            harness.capture.mouseMoved(with: harness.mouse(.mouseMoved, x: 100 + CGFloat(step) * 10))
        }
        harness.capture.scrollWheel(with: harness.scroll(dy: 3, phase: .changed))
        harness.capture.scrollWheel(with: harness.wheelNotch())
        #expect(!harness.coalescer.hasPending)
        #expect(!harness.coalescer.isTicking, "no input stage frame for input nobody receives")
        #expect(harness.sink.events.isEmpty)
    }
}

@MainActor
private final class RemoteCaptureTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
