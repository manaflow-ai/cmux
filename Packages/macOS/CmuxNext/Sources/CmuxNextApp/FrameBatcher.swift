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
    private var client: FrameClient!

    /// `owner` names the batcher in the wakeup ledger and debug.wakeups.
    init(owner: String, scheduler: FrameScheduler = .app) {
        client = FrameClient(owner: owner, isAnimation: false, on: scheduler) { [weak self] _ in
            self?.drain() ?? false
        }
    }

    nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        // task-owner: the frame hop itself; runs once
        Task { @MainActor in self.enqueue(work) }
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
