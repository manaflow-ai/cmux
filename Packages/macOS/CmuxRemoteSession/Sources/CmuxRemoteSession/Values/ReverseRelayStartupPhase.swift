internal import Foundation

/// Queue-confined phase for the asynchronous pre-launch relay cleanup.
enum ReverseRelayStartupPhase: Sendable {
    case idle
    case cancellingInheritedForward(
        token: UUID,
        task: Task<Void, Never>,
        cancellation: RemoteProcessCancellationOperation
    )

    var isIdle: Bool {
        if case .idle = self {
            return true
        }
        return false
    }

    var token: UUID? {
        guard case .cancellingInheritedForward(let token, _, _) = self else {
            return nil
        }
        return token
    }
}
