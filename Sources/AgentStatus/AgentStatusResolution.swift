/// The reconciler's status projection and how strongly current evidence supports it.
struct AgentStatusResolution: Equatable, Sendable {
    let lifecycle: AgentHibernationLifecycleState
    let confidence: AgentStatusConfidence
}
