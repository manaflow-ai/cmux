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
    private var latestBoundaryEpochs:
        [AgentObservedAttentionConclusionKey: UInt64] = [:]
    private var boundaryInsertionOrder:
        [AgentObservedAttentionConclusionKey] = []
    private var boundaryInsertionOrderHead = 0

    mutating func record(
        source: String,
        sessionId: String?,
        observationId: String?,
        scopeId: String?,
        processGeneration: AgentPIDProcessIdentity,
        boundaryEpoch: UInt64? = nil
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
        if let boundaryEpoch {
            recordBoundary(
                source: source,
                sessionId: sessionId,
                processGeneration: processGeneration,
                epoch: boundaryEpoch
            )
        }
    }

    func contains(
        source: String,
        sessionId: String,
        observationId: String,
        scopeId: String,
        processGeneration: AgentPIDProcessIdentity,
        observationEpoch: UInt64? = nil
    ) -> Bool {
        if let observationEpoch,
           let boundaryEpoch = latestBoundaryEpochs[
               .processBoundary(
                   source: source,
                   sessionId: sessionId,
                   generation: processGeneration
               )
           ],
           observationEpoch <= boundaryEpoch {
            return true
        }
        return keys.contains(
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

    private mutating func recordBoundary(
        source: String,
        sessionId: String,
        processGeneration: AgentPIDProcessIdentity,
        epoch: UInt64
    ) {
        let key = AgentObservedAttentionConclusionKey.processBoundary(
            source: source,
            sessionId: sessionId,
            generation: processGeneration
        )
        if let previous = latestBoundaryEpochs[key] {
            latestBoundaryEpochs[key] = max(previous, epoch)
            return
        }
        latestBoundaryEpochs[key] = epoch
        boundaryInsertionOrder.append(key)
        while latestBoundaryEpochs.count > Self.maximumCount,
              boundaryInsertionOrderHead < boundaryInsertionOrder.count {
            let expired = boundaryInsertionOrder[boundaryInsertionOrderHead]
            boundaryInsertionOrderHead += 1
            latestBoundaryEpochs.removeValue(forKey: expired)
        }
        if boundaryInsertionOrderHead >= Self.maximumCount,
           boundaryInsertionOrderHead * 2
                >= boundaryInsertionOrder.count {
            boundaryInsertionOrder.removeFirst(boundaryInsertionOrderHead)
            boundaryInsertionOrderHead = 0
        }
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
