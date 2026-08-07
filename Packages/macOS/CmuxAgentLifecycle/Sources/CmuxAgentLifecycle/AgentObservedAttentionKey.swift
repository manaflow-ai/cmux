/// Exact identity of one native approval observation.
public nonisolated struct AgentObservedAttentionKey: Hashable, Sendable {
    /// The normalized built-in integration source.
    public let source: String
    /// The integration-owned session identifier.
    public let sessionId: String
    /// The integration-owned observation identifier.
    public let observationId: String
    /// The exact process generation that emitted the observation.
    public let processGeneration: AgentProcessGeneration

    /// Creates an exact native-approval observation key.
    ///
    /// - Parameters:
    ///   - source: The normalized built-in integration source.
    ///   - sessionId: The integration-owned session identifier.
    ///   - observationId: The integration-owned observation identifier.
    ///   - processGeneration: The exact emitting process generation.
    public init(
        source: String,
        sessionId: String,
        observationId: String,
        processGeneration: AgentProcessGeneration
    ) {
        self.source = source
        self.sessionId = sessionId
        self.observationId = observationId
        self.processGeneration = processGeneration
    }
}
