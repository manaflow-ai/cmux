import CmuxFoundation

/// Retires one reload waiter exactly once, including after its socket timeout.
final class SocketReloadConfigurationWaiterLease: Sendable {
    private let admission:
        SocketReloadConfigurationWaiterAdmission
    private let didRetire = AtomicBooleanGate(false)

    init(
        admission:
            SocketReloadConfigurationWaiterAdmission
    ) {
        self.admission = admission
    }

    func retire() {
        guard didRetire.compareExchange(
            expected: false,
            desired: true
        ) else {
            return
        }
        admission.retireWaiter()
    }
}
