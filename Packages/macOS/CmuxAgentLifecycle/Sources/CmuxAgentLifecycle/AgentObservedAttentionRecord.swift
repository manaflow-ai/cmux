/// One active native-approval observation and its owner-defined target.
public nonisolated struct AgentObservedAttentionRecord<Target: Sendable>:
    Sendable
{
    /// The exact observation identity.
    public let key: AgentObservedAttentionKey
    /// The integration-owned scope used for grouped conclusions.
    public let scopeId: String
    /// The owner-defined state needed to retire the visible attention.
    public let target: Target

    /// Creates an active native-approval observation.
    ///
    /// - Parameters:
    ///   - key: The exact observation identity.
    ///   - scopeId: The integration-owned grouped-conclusion scope.
    ///   - target: The owner-defined state needed to retire the attention.
    public init(
        key: AgentObservedAttentionKey,
        scopeId: String,
        target: Target
    ) {
        self.key = key
        self.scopeId = scopeId
        self.target = target
    }
}
