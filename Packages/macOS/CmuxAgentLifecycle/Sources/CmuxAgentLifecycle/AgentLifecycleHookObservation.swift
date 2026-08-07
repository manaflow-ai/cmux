/// The latest admitted hook value and the process generation that owns it.
nonisolated struct AgentLifecycleHookObservation: Equatable, Sendable {
    var lifecycle: AgentLifecycleState
    var processGeneration: AgentProcessGeneration?
}
