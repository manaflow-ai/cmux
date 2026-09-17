enum TerminationWaitResult: Equatable, Sendable {
    case terminated
    case deadlineReached
    case cancelled
}
