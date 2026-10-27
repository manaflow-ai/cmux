public import AppKit
public import CmuxNextWakeups

/// A window's ``FrameInputCoalescer`` on a fake link whose frames come only when a test calls
/// ``frame()``, handed out by ``coalescers`` for every window (p04-input-030's coalescer, for the
/// per-frame pointer tests of p04-input-031, 033 and 037).
///
/// ```swift
/// let frames = FrameInputTestRig()
/// view.hoverFrameInput = frames.coalescers
/// view.mouseMoved(with: move) // the leading edge hovers now; later moves wait
/// frames.frame()              // the trailing hover lands
/// ```
@MainActor
public final class FrameInputTestRig {
    public let scheduler: FrameScheduler
    public let coalescer: FrameInputCoalescer
    public let coalescers: FrameInputCoalescers
    private var frames = 0

    public init() {
        let ledger = WakeupLedger()
        scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in FrameInputTestLink() }
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
        self.coalescer = coalescer
        coalescers = FrameInputCoalescers { _ in coalescer }
    }

    /// One 120 Hz link frame: the coalescer's trailing deliveries run.
    public func frame() {
        frames += 1
        scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
    }

    public func close() { coalescer.invalidate() }
}

@MainActor
private final class FrameInputTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
