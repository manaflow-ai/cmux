import CmuxNextControl
import CmuxNextDaemon
import CmuxNextWakeups

/// Runs main-actor batches once per display frame (architecture.md 2): the
/// daemon store drain, pane presentation, the control work queue, the
/// snapshot publisher and the invariant monitors each own one batcher.
///
/// A batcher is a ``FrameClient`` of ``FrameScheduler/app``: active only
/// while work is pending, so an idle app has no frame wakeups, and the
/// scheduler's stall deadline keeps work moving while the displays sleep
/// (state-audit D4).
@MainActor
final class FrameBatcher: FrameBatchScheduler, ControlFrameSource {
    private var pending: [@MainActor @Sendable () -> Void] = []
    private let owner: String
    private let scheduler: FrameScheduler
    /// Built in init (lazy because its callback captures self; no IUO).
    private lazy var client = FrameClient(owner: owner, isAnimation: false, on: scheduler) { [weak self] _ in
        self?.drain() ?? false
    }

    /// `owner` names the batcher in the wakeup ledger and debug.wakeups.
    init(owner: String, scheduler: FrameScheduler = .app) {
        self.owner = owner
        self.scheduler = scheduler
        _ = client  // built here, as before
    }

    /// Hops through the main run loop in the common modes, not a main-actor
    /// task: a native menu tracks inside a main-queue callout, where no
    /// main-actor job runs until the menu closes (``MainRunLoopHop``).
    nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform { self.enqueue(work) }
    }

    func enqueue(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.append(work)
        client.activate()
    }

    /// Runs the pending work; true while more arrived during it.
    private func drain() -> Bool {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        for work in works { work() }
        return !pending.isEmpty
    }
}
