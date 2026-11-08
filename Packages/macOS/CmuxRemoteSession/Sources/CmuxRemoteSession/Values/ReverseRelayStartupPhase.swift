internal import Foundation

/// Queue-confined phase for one conflict-triggered inherited-master recovery.
enum ReverseRelayStartupPhase: Sendable {
    case recoveryAvailable
    case reapingInheritedControlMaster(
        token: UUID,
        task: Task<Void, Never>
    )
    case recoveryAttempted

    var allowsRelayLaunch: Bool {
        if case .reapingInheritedControlMaster = self {
            return false
        }
        return true
    }

    var canAttemptRecovery: Bool {
        if case .recoveryAvailable = self {
            return true
        }
        return false
    }

    var token: UUID? {
        guard case .reapingInheritedControlMaster(
            let token,
            _
        ) = self else {
            return nil
        }
        return token
    }
}
