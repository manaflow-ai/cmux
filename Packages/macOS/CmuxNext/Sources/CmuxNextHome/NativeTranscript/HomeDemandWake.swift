import CmuxNextWakeups
import MessagesLabHome

/// The MessagesLab controller's engine-clock wake-ups on CmuxNext's one-shot
/// timer (no sleep, no polling; each fire is recorded in the wakeup ledger).
final class HomeDemandWake: ChatWakeScheduler {
    private let timer = DemandTimer(owner: "Home.transcript.wake")

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer.schedule(after: .seconds(max(0, seconds))) { @MainActor in action() }
    }

    func cancel() { timer.cancel() }
}
