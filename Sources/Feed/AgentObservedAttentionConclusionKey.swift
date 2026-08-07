/// One session- and generation-scoped native-attention conclusion identity.
nonisolated enum AgentObservedAttentionConclusionKey: Hashable {
    case observation(
        source: String,
        sessionId: String,
        id: String,
        generation: AgentPIDProcessIdentity
    )
    case scope(
        source: String,
        sessionId: String,
        id: String,
        generation: AgentPIDProcessIdentity
    )
    case processBoundary(
        source: String,
        sessionId: String,
        generation: AgentPIDProcessIdentity
    )
}
