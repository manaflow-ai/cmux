/// The reason an automation process was forcefully terminated.
nonisolated enum AutomationProcessTerminationReason: Sendable {
    case cancelled
    case timedOut
}
