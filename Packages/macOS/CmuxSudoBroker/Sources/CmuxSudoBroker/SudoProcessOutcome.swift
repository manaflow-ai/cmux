enum SudoProcessOutcome: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case authenticationFailed(cleanupSurvivors: [SudoProcessIdentity])
    case timedOut(cleanupSurvivors: [SudoProcessIdentity])
}
