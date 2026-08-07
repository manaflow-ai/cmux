/// One lifecycle value together with the authority that produced it.
nonisolated struct AgentLifecycleResolution: Sendable {
    let lifecycle: AgentLifecycleState
    let confidence: AgentLifecycleConfidence
}
