import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// `CmuxApplication.sendEvent`'s observe stage: the windows' pending continuous input
/// is flushed before any tap observer sees a discrete event (Chromium's ShouldFlushQueue), so an
/// observer that subscribed at launch, before the window's consumer existed, still sees the moves first.
@MainActor @Suite struct CmuxApplicationFrameInputFlushTests {
    /// What the handlers saw: a class, so `@MainActor` handlers share it without a captured `var`.
    private final class Log {
        var events: [String] = []
    }

    @Test func aButtonObserverSubscribedFirstStillSeesTheFlushedMovesFirst() throws {
        _ = NSApplication.shared
        let tap = InputEventTap()
        let log = Log()
        let button = tap.subscribe(class: .button) { _ in log.events.append("button") }

        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            FlushTestLink()
        }
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        let coalescers = FrameInputCoalescers { _ in coalescer }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let hover = coalescers.coalescer(for: window).consumer(owner: "hover") { input in
            log.events.append("move \(Int(input.latest.location.x))")
        }
        for x in 0..<3 {
            hover.post(InputEventRecord(type: .mouseMoved, timestamp: 1, windowNumber: 1, location: InputPoint(x: Double(x), y: 0)))
        }
        #expect(log.events == ["move 0"], "the leading move; the others wait for the frame")

        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tap.dispatching { CmuxApplication.deliverObserveStage(down, tap: tap, frameInput: coalescers) }
        #expect(log.events == ["move 0", "move 2", "button"])
        #expect(!coalescers.hasPending)
        coalescer.invalidate()
        withExtendedLifetime(button) {}
    }
}

@MainActor
private final class FlushTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
