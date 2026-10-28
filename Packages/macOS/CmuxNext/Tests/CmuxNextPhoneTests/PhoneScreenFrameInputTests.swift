import AppKit
@testable import CmuxNextPhone
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A phone screen's touch moves once per frame (feature `pointerFrameRemoteInput`): with
/// the window's FrameInputCoalescer a frame interval's first drag goes to the phone at
/// once and the rest once at the frame, to the latest point; the touch's start and end send what waits
/// first, so the phone sees the last move before the touch ends (Chromium's rAF-aligned input and
/// `ShouldFlushQueue`, `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`).
@MainActor @Suite(.serialized) struct PhoneScreenFrameInputTests {
    struct Touch: Equatable {
        var phase: PhoneTouch.Phase
        /// The 0...1 screen x.
        var x: Double
    }

    @MainActor final class Harness {
        let view = PhoneScreenView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        var touches: [Touch] = []
        private var frames = 0

        /// `coalesced`: the drags go through the window's coalescer (the feature on).
        init(coalesced: Bool = true) {
            _ = NSApplication.shared
            let ledger = WakeupLedger()
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in PhoneScreenTestLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
            self.coalescer = coalescer
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            // A still frame the size of the view: the screen fills it, x maps to x / 800.
            view.show(image: NSImage(size: NSSize(width: 800, height: 600)))
            view.onTouch = { [unowned self] phase, point in self.touches.append(Touch(phase: phase, x: Double(point.x))) }
            view.pointerFrames = coalesced ? FrameInputCoalescers { _ in coalescer } : nil
        }

        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// One 120 Hz link frame: the coalescer's trailing deliveries run.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        var moves: Int { touches.filter { $0.phase == .moved }.count }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight drags in one frame: the phone gets the first move at once and the latest once at the frame.
    @Test func eightDragsInOneFrameSendTwoMoves() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.mouseDown(with: harness.mouse(.leftMouseDown, x: 100))
        harness.frame()
        for step in 1...8 {
            harness.view.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.touches == [Touch(phase: .began, x: 0.125), Touch(phase: .moved, x: 0.1375)], "the leading move went in its own turn")
        harness.frame()
        #expect(harness.touches.last == Touch(phase: .moved, x: 0.225), "the frame sent the latest point once")
        #expect(harness.moves == 2)
        harness.frame()
        #expect(harness.moves == 2, "an idle frame sends nothing")
    }

    /// The release sends the waiting move first: the touch ends after its last move, at its point.
    @Test func theTouchEndsAfterItsLastMove() {
        let harness = Harness()
        defer { harness.close() }
        harness.view.mouseDown(with: harness.mouse(.leftMouseDown, x: 100))
        for step in 1...6 {
            harness.view.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 100 + CGFloat(step) * 10))
        }
        harness.view.mouseUp(with: harness.mouse(.leftMouseUp, x: 160))
        #expect(harness.touches == [Touch(phase: .began, x: 0.125), Touch(phase: .moved, x: 0.1375), Touch(phase: .moved, x: 0.2),
                                    Touch(phase: .ended, x: 0.2)])
        #expect(!harness.coalescer.hasPending)
    }

    /// Without the coalescer (the feature off) every drag is a move at once.
    @Test func withoutTheCoalescerEveryDragIsAMove() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        harness.view.mouseDown(with: harness.mouse(.leftMouseDown, x: 100))
        for step in 1...8 {
            harness.view.mouseDragged(with: harness.mouse(.leftMouseDragged, x: 100 + CGFloat(step) * 10))
        }
        #expect(harness.moves == 8)
    }
}

@MainActor
private final class PhoneScreenTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
