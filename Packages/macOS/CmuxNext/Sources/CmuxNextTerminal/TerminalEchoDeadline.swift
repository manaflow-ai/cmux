import CmuxNextWakeups

/// A one-shot deadline that a newer schedule replaces (``DemandTimer`` in the app; a manual one in tests).
public nonisolated protocol TerminalEchoDeadline: Sendable {
    /// Runs `fire` once after `delay`, replacing any pending schedule.
    func schedule(after delay: Duration, _ fire: @escaping @Sendable () -> Void)
    /// Drops the pending schedule.
    func cancel()
}

/// ``TerminalEchoDeadline`` on the app's ``DemandTimer``.
nonisolated struct DemandEchoDeadline: TerminalEchoDeadline {
    let timer: DemandTimer

    func schedule(after delay: Duration, _ fire: @escaping @Sendable () -> Void) {
        timer.schedule(after: delay) { fire() }
    }

    func cancel() {
        timer.cancel()
    }
}
