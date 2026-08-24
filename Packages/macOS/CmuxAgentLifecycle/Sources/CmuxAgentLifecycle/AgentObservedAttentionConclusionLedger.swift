/// Bounded tombstones that make native attention delivery idempotent.
///
/// Observation and scope identifiers are opaque adapter correlations. Their
/// exact session and process generation prevent a reused numeric PID or a
/// sibling session from inheriting an earlier conclusion.
public nonisolated struct AgentObservedAttentionConclusionLedger {
    private struct QueueEntry {
        let key: AgentObservedAttentionConclusionKey
        let generation: UInt64
    }

    private static let maximumCount = 4_096
    private var keys: Set<AgentObservedAttentionConclusionKey> = []
    private var insertionOrder: [QueueEntry] = []
    private var insertionOrderHead = 0
    private var insertionGenerationByKey:
        [AgentObservedAttentionConclusionKey: UInt64] = [:]
    private var latestBoundaryEpochs:
        [AgentObservedAttentionConclusionKey: UInt64] = [:]
    private var boundaryInsertionOrder: [QueueEntry] = []
    private var boundaryInsertionOrderHead = 0
    private var boundaryInsertionGenerationByKey:
        [AgentObservedAttentionConclusionKey: UInt64] = [:]
    private var nextQueueGeneration: UInt64 = 0

    /// Creates an empty conclusion ledger.
    public init() {}

    /// Records exact identifiers or a monotonic process boundary as concluded.
    ///
    /// - Parameters:
    ///   - source: The built-in integration's normalized Feed source.
    ///   - sessionId: The exact integration session, when known.
    ///   - observationId: The exact native observation identifier, when known.
    ///   - scopeId: The exact native approval scope, when known.
    ///   - processGeneration: The process generation that owned the observation.
    ///   - boundaryEpoch: A monotonic process-local conclusion boundary, when
    ///     supplied by the observer.
    public mutating func record(
        source: String,
        sessionId: String?,
        observationId: String?,
        scopeId: String?,
        processGeneration: AgentProcessGeneration,
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

    /// Returns whether an incoming observation was already concluded.
    ///
    /// - Parameters:
    ///   - source: The built-in integration's normalized Feed source.
    ///   - sessionId: The exact integration session.
    ///   - observationId: The exact native observation identifier.
    ///   - scopeId: The exact native approval scope.
    ///   - processGeneration: The process generation that owns the observation.
    ///   - observationEpoch: The observation's monotonic process-local epoch,
    ///     when supplied by the observer.
    /// - Returns: `true` when either exact identifier or an equal-or-newer
    ///   process boundary already concluded the observation.
    public func contains(
        source: String,
        sessionId: String,
        observationId: String,
        scopeId: String,
        processGeneration: AgentProcessGeneration,
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
        processGeneration: AgentProcessGeneration,
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
        let generation = nextQueueGenerationValue()
        boundaryInsertionGenerationByKey[key] = generation
        boundaryInsertionOrder.append(
            QueueEntry(key: key, generation: generation)
        )
        while latestBoundaryEpochs.count > Self.maximumCount,
              boundaryInsertionOrderHead < boundaryInsertionOrder.count {
            let expired = boundaryInsertionOrder[boundaryInsertionOrderHead]
            boundaryInsertionOrderHead += 1
            guard boundaryInsertionGenerationByKey[expired.key]
                    == expired.generation else {
                continue
            }
            boundaryInsertionGenerationByKey.removeValue(forKey: expired.key)
            latestBoundaryEpochs.removeValue(forKey: expired.key)
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
        let generation = nextQueueGenerationValue()
        insertionGenerationByKey[key] = generation
        insertionOrder.append(
            QueueEntry(key: key, generation: generation)
        )
        while keys.count > Self.maximumCount,
              insertionOrderHead < insertionOrder.count {
            let expired = insertionOrder[insertionOrderHead]
            insertionOrderHead += 1
            guard insertionGenerationByKey[expired.key]
                    == expired.generation else {
                continue
            }
            insertionGenerationByKey.removeValue(forKey: expired.key)
            keys.remove(expired.key)
        }
        if insertionOrderHead >= Self.maximumCount,
           insertionOrderHead * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(insertionOrderHead)
            insertionOrderHead = 0
        }
    }

    private mutating func nextQueueGenerationValue() -> UInt64 {
        nextQueueGeneration &+= 1
        return nextQueueGeneration
    }
}
