/// Whether a PID registration introduces a runtime or moves an existing one.
enum AgentStatusRuntimeRegistrationSource: Equatable, Sendable {
    case discovered
    case transferred
}
