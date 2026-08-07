enum AgentWaitStatus: String, Sendable, Equatable {
    case satisfied
    case timedOut = "timed_out"
    case surfaceClosed = "surface_closed"
}
