import AppKit
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// A window's ``FrameInputCoalescer`` on a fake link whose frames come only when a test calls
/// ``frame()``, handed out by ``coalescers`` for every window (p04-input-030's coalescer, for the
/// resize-handle tests of p04-input-031).
@MainActor
final class PointerFrameTestRig {
    let scheduler: FrameScheduler
    let coalescer: FrameInputCoalescer
    let coalescers: FrameInputCoalescers
    private var frames = 0

    init() {
        let ledger = WakeupLedger()
        scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in PointerFrameTestLink() }
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
        self.coalescer = coalescer
        coalescers = FrameInputCoalescers { _ in coalescer }
    }

    /// One 120 Hz link frame: the coalescer's trailing deliveries run.
    func frame() {
        frames += 1
        scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
    }

    func close() { coalescer.invalidate() }
}

@MainActor
private final class PointerFrameTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
