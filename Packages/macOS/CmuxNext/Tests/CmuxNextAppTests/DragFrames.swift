import AppKit
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The frames of a drag test: every window's input coalescer is one coalescer on a scheduler whose
/// link ticks only when the test calls ``tick()``; neither the scheduler's stall timer nor the
/// coalescer's fallback fires (their clocks never advance), so each frame in a test is one the test
/// delivered.
@MainActor
final class DragFrames {
    let scheduler: FrameScheduler
    /// The one coalescer every window gets.
    let coalescer: FrameInputCoalescer
    /// The coalescers a drag gets (`AppServices.frameInput`, `PaneSwapDrag`'s `frames`).
    let coalescers: FrameInputCoalescers
    private var timestamp: CFTimeInterval = 1000

    init() {
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in DragFrameLink() }
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        (self.scheduler, self.coalescer) = (scheduler, coalescer)
        coalescers = FrameInputCoalescers(make: { _ in coalescer })
    }

    /// One 120 Hz display frame: the frame's coalesced moves run.
    func tick() {
        timestamp += 1.0 / 120
        scheduler.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 120)
    }
}

@MainActor
private final class DragFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
