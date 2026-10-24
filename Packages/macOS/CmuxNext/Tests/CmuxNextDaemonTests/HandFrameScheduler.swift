import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextWakeups

/// A ``FrameBatchScheduler`` whose frames the test fires by hand. Each frame begins `budget`'s
/// window and runs the scheduled work as one visible-class task, as the app's `FrameBatcher`
/// (`DaemonStore.drain`, `.budgeted(.visible)`) does.
final class HandFrameScheduler: FrameBatchScheduler {
    private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])
    let budget: MainFrameBudget

    init(budget: MainFrameBudget) {
        self.budget = budget
    }

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0.append(work) }
    }

    @MainActor var mainFrameBudget: MainFrameBudget? { budget }

    /// Frames requested and not fired yet.
    var scheduled: Int { pending.withLock { $0.count } }

    /// Fires one display frame: what was scheduled before it runs under the budget.
    @MainActor func fire(timestamp: Double) {
        budget.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        let work = pending.withLock { pending in
            defer { pending.removeAll() }
            return pending
        }
        for item in work { budget.run(.visible, owner: "DaemonStore.drain") { item() } }
    }

    /// Runs `body` as the frame's visible task, as a frame the pump scheduled would.
    @MainActor func frame(timestamp: Double, _ body: () -> Void) {
        budget.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        budget.run(.visible, owner: "DaemonStore.drain", body)
    }
}
