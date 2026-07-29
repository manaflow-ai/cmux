internal import Foundation

/// Queue-confined phase for one conflict-triggered legacy-master recovery.
enum ReverseRelayStartupPhase: Sendable {
    case recoveryAvailable
    case exitingConflictedControlMaster(
        token: UUID,
        task: Task<Void, Never>,
        cancellation: RemoteProcessCancellationOperation
    )
    case recoveryAttempted

    var allowsRelayLaunch: Bool {
        if case .exitingConflictedControlMaster = self {
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

    var isRecovering: Bool {
        if case .exitingConflictedControlMaster = self {
            return true
        }
        return false
    }

    var token: UUID? {
        guard case .exitingConflictedControlMaster(let token, _, _) = self else {
            return nil
        }
        return token
    }
}
