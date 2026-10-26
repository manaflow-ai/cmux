import CmuxNextWakeups

/// The one-shot deadline of a window's next top page discard (a ``DemandTimer`` in the app, a fake in tests).
@MainActor
protocol TopPageDiscardDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func arm(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void)
    /// Drops the pending deadline.
    func disarm()
}

extension DemandTimer: TopPageDiscardDeadline {
    func arm(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        schedule(after: delay) { @MainActor in action() }
    }

    func disarm() { cancel() }
}
