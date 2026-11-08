/// The reason an automation process was forcefully terminated.
enum AutomationProcessTerminationReason: Sendable {
    case cancelled
    case timedOut
}
