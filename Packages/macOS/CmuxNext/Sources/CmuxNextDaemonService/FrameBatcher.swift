public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextWakeups

/// Runs main-actor batches once per display frame (architecture.md 2): the
/// daemon store drain, pane presentation, the control work queue, the
/// snapshot publisher and the invariant monitors each own one batcher.
///
/// A batcher is a ``FrameClient`` of ``FrameScheduler/app``: active only
/// while work is pending, so an idle app has no frame wakeups, and the
/// scheduler's stall deadline keeps work moving while the displays sleep
/// (state-audit D4).
///
/// Each batcher runs through a ``FrameBatchQueue`` of a kind its owner picks: `frame` (all of it
/// every frame, for what a person's action caused) or a budgeted class (one task at a time under
/// the class's per-frame budget, ``MainFrameBudget``, yielding to a person's pending input, the
/// rest on the next frame).
@MainActor
public final class FrameBatcher: FrameBatchScheduler, ControlFrameSource {
    /// The queue that runs the batches (``FrameBatchQueue``, the one batch primitive).
    public let queue: FrameBatchQueue
    /// The batcher's priority class.
    public let workClass: MainWorkClass
    /// The board of the budget this batcher draws on (control requests count queued input there).
    public nonisolated let mainTaskBoard: MainTaskBoard?

    /// - Parameters:
    ///   - owner: Names the batcher in the wakeup ledger, debug.wakeups and the watchdog's stall records.
    ///   - kind: ``FrameBatchQueue/Kind/frame`` for work a person's action caused (never held);
    ///     budgeted `visible` for screen updates no action of the person caused (the daemon's churn),
    ///     `automation` for control-socket work, `background` for work nobody sees this frame.
    ///   - scheduler: The frame scheduler (default ``FrameScheduler/app``).
    public init(owner: String, kind: FrameBatchQueue.Kind = .frame, scheduler: FrameScheduler = .app) {
        queue = FrameBatchQueue(owner: owner, kind: kind, scheduler: scheduler)
        switch kind {
        case .frame: workClass = .frame
        case .budgeted(let budgeted): workClass = budgeted.workClass
        }
        self.mainTaskBoard = scheduler.budget.board
    }

    /// The budget this batcher's work draws on (the control work queue charges its requests to it).
    public var mainFrameBudget: MainFrameBudget? { queue.scheduler.budget }

    /// Hops through the main run loop in the common modes, not a main-actor
    /// task: a native menu tracks inside a main-queue callout, where no
    /// main-actor job runs until the menu closes (``MainRunLoopHop``).
    public nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform { self.queue.enqueue(work) }
    }

    /// The next main run loop turn, without waiting for a display frame
    /// (the control work queue's first request after idle).
    public nonisolated func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform(work)
    }
}
