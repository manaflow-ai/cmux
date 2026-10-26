public import CmuxNextWakeups

/// The one-shot deadline of a host's next page discard (a ``DemandTimer`` in the app, a fake in tests).
@MainActor
public protocol PageDiscardDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func arm(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void)
    /// Drops the pending deadline.
    func disarm()
}

extension DemandTimer: PageDiscardDeadline {
    public func arm(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        schedule(after: delay) { @MainActor in action() }
    }

    public func disarm() { cancel() }
}
