/// Reconciliation state retained for one native approval observation.
nonisolated struct FeedObservedAttentionState {
    let scopeId: String
    let processGeneration: AgentPIDProcessIdentity
    let target: FeedAttentionTarget
}
