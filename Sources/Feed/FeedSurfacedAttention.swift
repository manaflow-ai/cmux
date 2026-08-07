/// Result of surfacing an attention overlay against its resolved owner.
nonisolated struct FeedSurfacedAttention {
    let target: FeedAttentionTarget
    let usesRemoteProcessNamespace: Bool
    let processGeneration: AgentPIDProcessIdentity?
}
