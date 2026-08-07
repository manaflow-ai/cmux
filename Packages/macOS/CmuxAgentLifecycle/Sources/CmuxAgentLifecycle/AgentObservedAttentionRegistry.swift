/// Bounded active-state registry for native approval observations.
///
/// The registry deliberately returns evicted and removed records to its owner.
/// That keeps visible-state cleanup in the same mutation path as retention and
/// prevents a dropped conclusion from growing owner state without limit.
public nonisolated struct AgentObservedAttentionRegistry<Target: Sendable>:
    Sendable
{
    private struct StoredRecord: Sendable {
        var insertionSequence: UInt64
        let record: AgentObservedAttentionRecord<Target>
    }

    private let maximumCount: Int
    private var nextInsertionSequence: UInt64 = 0
    private var recordsByKey:
        [AgentObservedAttentionKey: StoredRecord] = [:]

    /// Creates a registry with a hard active-observation limit.
    ///
    /// - Parameter maximumCount: The maximum retained active observations.
    ///   Values below one are clamped to one.
    public init(maximumCount: Int = 256) {
        self.maximumCount = max(1, maximumCount)
    }

    /// The number of active observations currently retained.
    public var count: Int { recordsByKey.count }

    /// Returns the active record for an exact observation key.
    ///
    /// - Parameter key: The exact observation identity.
    /// - Returns: The retained record, when present.
    public func record(
        for key: AgentObservedAttentionKey
    ) -> AgentObservedAttentionRecord<Target>? {
        recordsByKey[key]?.record
    }

    /// Inserts a new active observation and evicts the oldest excess record.
    ///
    /// - Parameter record: The observation to retain.
    /// - Returns: `nil` when the exact key already exists; otherwise, every
    ///   record evicted to preserve ``maximumCount`` (normally zero or one).
    @discardableResult
    public mutating func insert(
        _ record: AgentObservedAttentionRecord<Target>
    ) -> [AgentObservedAttentionRecord<Target>]? {
        guard recordsByKey[record.key] == nil else { return nil }
        let sequence = takeNextInsertionSequence()
        recordsByKey[record.key] = StoredRecord(
            insertionSequence: sequence,
            record: record
        )

        var evicted: [AgentObservedAttentionRecord<Target>] = []
        while recordsByKey.count > maximumCount,
              let oldest = recordsByKey.min(by: {
                  $0.value.insertionSequence < $1.value.insertionSequence
              }) {
            recordsByKey.removeValue(forKey: oldest.key)
            evicted.append(oldest.value.record)
        }
        return evicted
    }

    /// Removes and returns every record matching an owner-defined condition.
    ///
    /// Returning removed records makes it impossible for the registry owner to
    /// forget the corresponding visible-state cleanup.
    ///
    /// - Parameter shouldRemove: Returns `true` for records to retire.
    /// - Returns: The retired records.
    @discardableResult
    public mutating func remove(
        where shouldRemove: (AgentObservedAttentionRecord<Target>) -> Bool
    ) -> [AgentObservedAttentionRecord<Target>] {
        let keys = recordsByKey.compactMap { key, stored in
            shouldRemove(stored.record) ? key : nil
        }
        return keys.compactMap {
            recordsByKey.removeValue(forKey: $0)?.record
        }
    }

    /// Whether any active record matches an owner-defined condition.
    ///
    /// - Parameter predicate: Returns `true` for a matching record.
    /// - Returns: `true` when at least one active observation matches.
    public func contains(
        where predicate: (AgentObservedAttentionRecord<Target>) -> Bool
    ) -> Bool {
        recordsByKey.values.contains { predicate($0.record) }
    }

    private mutating func takeNextInsertionSequence() -> UInt64 {
        if nextInsertionSequence == .max {
            rebaseInsertionSequences()
        }
        let sequence = nextInsertionSequence
        nextInsertionSequence += 1
        return sequence
    }

    private mutating func rebaseInsertionSequences() {
        let ordered = recordsByKey.sorted {
            $0.value.insertionSequence < $1.value.insertionSequence
        }
        for (index, entry) in ordered.enumerated() {
            recordsByKey[entry.key]?.insertionSequence = UInt64(index)
        }
        nextInsertionSequence = UInt64(ordered.count)
    }
}
