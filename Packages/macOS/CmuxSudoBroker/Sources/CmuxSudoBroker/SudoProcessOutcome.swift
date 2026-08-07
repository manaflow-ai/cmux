enum SudoProcessOutcome: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut(cleanupSurvivors: [SudoProcessIdentity])
}
