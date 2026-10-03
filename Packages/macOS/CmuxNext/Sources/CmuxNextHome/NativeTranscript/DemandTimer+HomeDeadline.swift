import CmuxHomeRender
import CmuxNextWakeups

/// The render core's cleanup deadline on CmuxNext's one-shot timer (no
/// sleep, no polling; each fire is recorded in the wakeup ledger).
final class HomeDemandDeadline: HomeDeadline {
    private let timer = DemandTimer(owner: "Home.transcript.cleanup")

    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer.schedule(after: delay) { @MainActor in action() }
    }

    func cancel() { timer.cancel() }
}
