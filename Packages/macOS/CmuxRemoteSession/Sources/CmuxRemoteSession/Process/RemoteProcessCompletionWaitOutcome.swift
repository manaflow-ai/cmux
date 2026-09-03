enum RemoteProcessCompletionWaitOutcome: Equatable, Sendable {
    case processExited
    case stdinWriteFailed
    case timedOut
    case waitFailed(Int32)
}
