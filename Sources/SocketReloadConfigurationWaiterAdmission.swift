import CmuxFoundation

/// Caps synchronous `reload_config` waiters until their async callbacks retire.
///
/// A socket timeout does not cancel the main-actor reload or its escaping
/// completion. The lease therefore remains claimed until that completion runs,
/// preventing repeated timeout waves from accumulating queued callbacks.
final class SocketReloadConfigurationWaiterAdmission: Sendable {
    private let maximumConcurrentWaiters: UInt64
    private let activeWaiters = AtomicUInt64Value()

    init(maximumConcurrentWaiters: Int) {
        precondition(maximumConcurrentWaiters > 0)
        self.maximumConcurrentWaiters =
            UInt64(maximumConcurrentWaiters)
    }

    func claim() -> SocketReloadConfigurationWaiterLease? {
        guard activeWaiters.incrementIfBelow(
            maximumConcurrentWaiters
        ) else {
            return nil
        }
        return SocketReloadConfigurationWaiterLease(
            admission: self
        )
    }

    func retireWaiter() {
        precondition(
            activeWaiters.decrementIfPositive(),
            "Only a claimed reload waiter can retire"
        )
    }
}
