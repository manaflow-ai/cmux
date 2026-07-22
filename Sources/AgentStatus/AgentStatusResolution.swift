/// The reconciler's status projection and how strongly current evidence supports it.
struct AgentStatusResolution: Equatable, Sendable {
    enum Confidence: Int, Equatable, Sendable {
        case uncertain
        case inferred
        case confident
    }

    let lifecycle: AgentHibernationLifecycleState
    let confidence: Confidence
}
