/// The root-owned supervisor's terminal disposition.
enum SudoPrivilegedProcessOutcome: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case cleanupFailed
    case launchFailed
}
