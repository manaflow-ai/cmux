public import CmuxNextWakeups

/// The one-shot deadline of a host's next page discard: a ``MainDeadline`` in the `background`
/// class in the app (a discard tears down what nobody sees, so it waits behind input and visible
/// work, as Chrome posts proactive discards as low-priority work), a fake in tests.
@MainActor
public protocol PageDiscardDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func disarm()
}

extension MainDeadline: PageDiscardDeadline {
    public func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        schedule(after: delay, action)
    }

    public func disarm() { cancel() }
}
