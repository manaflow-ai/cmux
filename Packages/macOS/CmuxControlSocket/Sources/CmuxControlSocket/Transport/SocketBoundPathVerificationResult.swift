/// Result of proving that a pathname still routes to a retained bound listener.
enum SocketBoundPathVerificationResult: Equatable, Sendable {
    case verified(SocketPathIdentity)
    case pending(SocketStageFailure)
    case failed(SocketStageFailure)
}
