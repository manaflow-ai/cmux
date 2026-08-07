/// Exact identity of one native approval observation.
nonisolated struct FeedObservedAttentionKey: Hashable {
    let source: String
    let sessionId: String
    let observationId: String
    let processGeneration: AgentPIDProcessIdentity
}
