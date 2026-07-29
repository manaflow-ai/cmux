@testable import CmuxControlSocket

final class FixedRemotePTYLifecycleCommitLease:
    ControlRemotePTYLifecycleCommitLease,
    Sendable
{
    let isCurrent: Bool

    init(isCurrent: Bool) {
        self.isCurrent = isCurrent
    }

    @MainActor
    func commitIfCurrent(
        _ operation: @MainActor @Sendable () -> Bool
    ) -> Bool {
        guard isCurrent else { return false }
        return operation()
    }
}
