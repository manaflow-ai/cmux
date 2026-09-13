/// In-memory association store implementing heuristic-once and title-lock rules.
///
/// Pure value type with no filesystem I/O. Plugin bridges may mirror the same
/// semantics on disk; native cmux keeps this in memory keyed by compound IDs.
public struct NestedAssociationStore: Hashable, Codable, Sendable {
    private var records: [NestedAssociationKey: NestedAssociationRecord]

    /// Creates an empty store.
    public init() {
        self.records = [:]
    }

    /// Number of association records.
    public var count: Int { records.count }

    /// Returns the record for a key, if present.
    public func record(for key: NestedAssociationKey) -> NestedAssociationRecord? {
        records[key]
    }

    /// Whether heuristic association may still run for the key.
    public func shouldRunHeuristic(for key: NestedAssociationKey) -> Bool {
        records[key]?.shouldRunHeuristic ?? true
    }

    /// Records a successful heuristic/prompt association and marks heuristic satisfied.
    ///
    /// Once satisfied, subsequent calls leave the first parentID unchanged.
    public mutating func markHeuristicSatisfied(
        for key: NestedAssociationKey,
        parentID: NestedNodeID?
    ) {
        var record = records[key] ?? NestedAssociationRecord(key: key)
        guard !record.heuristicSatisfied else { return }
        record.parentID = parentID ?? record.parentID
        record.heuristicSatisfied = true
        records[key] = record
    }

    /// Drops association records for a superseded provider instance generation.
    public mutating func drop(providerInstanceGeneration: NestedProviderInstanceID) {
        records = records.filter { $0.key.providerInstanceGeneration != providerInstanceGeneration }
    }

    /// Installs or updates an explicit native-title lock.
    public mutating func lockTitle(
        for key: NestedAssociationKey,
        title: String,
        authority: NestedTitleAuthority
    ) {
        var record = records[key] ?? NestedAssociationRecord(key: key)
        record.titleLock = .locked(title, authority: authority)
        records[key] = record
    }

    /// Proposes a title update, suppressing overwrite when a lock is active.
    ///
    /// - Returns: The title that should be published, and whether an overwrite was suppressed.
    public func proposeTitle(
        for key: NestedAssociationKey,
        proposed: String
    ) -> (title: String, suppressedOverwrite: Bool) {
        guard let record = records[key] else {
            return (proposed, false)
        }
        let suppressed = record.wouldOverwriteLockedTitle(with: proposed)
        return (record.resolvedTitle(proposed: proposed), suppressed)
    }

    /// Drops associations whose provider instance generation no longer matches.
    public mutating func invalidate(providerInstanceGeneration: NestedProviderInstanceID) {
        records = records.filter { $0.key.providerInstanceGeneration == providerInstanceGeneration }
    }

    /// Removes one association key.
    public mutating func remove(_ key: NestedAssociationKey) {
        records.removeValue(forKey: key)
    }
}
