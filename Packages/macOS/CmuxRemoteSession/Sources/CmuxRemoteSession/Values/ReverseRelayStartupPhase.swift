/// Queue-confined phase for one inherited-forward cancellation attempt.
enum ReverseRelayStartupPhase: Sendable {
    case recoveryAvailable
    case recoveryAttempted

    var canAttemptRecovery: Bool {
        if case .recoveryAvailable = self {
            return true
        }
        return false
    }
}
