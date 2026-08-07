/// Bounded tombstones that make native attention delivery idempotent.
///
/// Observation and scope identifiers are opaque adapter correlations. Their
/// exact session and process generation prevent a reused numeric PID or a
/// sibling session from inheriting an earlier conclusion.
nonisolated struct AgentObservedAttentionConclusionLedger {
    private static let maximumCount = 4_096
    private var keys: Set<AgentObservedAttentionConclusionKey> = []
    private var insertionOrder: [AgentObservedAttentionConclusionKey] = []
    private var insertionOrderHead = 0

    mutating func record(
        source: String,
        sessionId: String?,
        observationId: String?,
        scopeId: String?,
        processGeneration: AgentPIDProcessIdentity
    ) {
        guard let sessionId else { return }
        if let observationId {
            insert(
                .observation(
                    source: source,
                    sessionId: sessionId,
                    id: observationId,
                    generation: processGeneration
                )
            )
        }
        if let scopeId {
            insert(
                .scope(
                    source: source,
                    sessionId: sessionId,
                    id: scopeId,
                    generation: processGeneration
                )
            )
        }
    }

    func contains(
        source: String,
        sessionId: String,
        observationId: String,
        scopeId: String,
        processGeneration: AgentPIDProcessIdentity
    ) -> Bool {
        keys.contains(
            .observation(
                source: source,
                sessionId: sessionId,
                id: observationId,
                generation: processGeneration
            )
        ) || keys.contains(
            .scope(
                source: source,
                sessionId: sessionId,
                id: scopeId,
                generation: processGeneration
            )
        )
    }

    private mutating func insert(
        _ key: AgentObservedAttentionConclusionKey
    ) {
        guard keys.insert(key).inserted else { return }
        insertionOrder.append(key)
        while keys.count > Self.maximumCount,
              insertionOrderHead < insertionOrder.count {
            let expired = insertionOrder[insertionOrderHead]
            insertionOrderHead += 1
            keys.remove(expired)
        }
        if insertionOrderHead >= Self.maximumCount,
           insertionOrderHead * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(insertionOrderHead)
            insertionOrderHead = 0
        }
    }
}
