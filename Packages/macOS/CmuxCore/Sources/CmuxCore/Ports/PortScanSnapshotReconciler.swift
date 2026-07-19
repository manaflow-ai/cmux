/// Reconciles best-effort port scans into a stable published snapshot.
///
/// Positive observations are applied immediately. Incomplete scans never remove
/// authoritative ports, while tentative ports learned only from incomplete scans
/// are recency-bounded. Complete scans must miss a previously observed port
/// repeatedly before it is removed. Explicitly untracked keys clear immediately.
public struct PortScanSnapshotReconciler<Key: Hashable & Sendable>: Sendable {
    /// The stable ports currently safe to publish, keyed by scan scope.
    public private(set) var snapshot: [Key: [Int]] = [:]

    private let missingPortRetentionLimit: Int
    private let maximumIncompletePortsPerKey: Int
    private var missingObservationCounts: [Key: [Int: Int]] = [:]
    private var incompletePortsByKey: [Key: Set<Int>] = [:]
    private var incompletePortObservationSequenceByKey: [Key: [Int: UInt64]] = [:]
    private var observationSequence: UInt64 = 0

    /// Creates a reconciler.
    ///
    /// - Parameter missingPortRetentionLimit: The number of consecutive complete
    ///   scans that may miss a known port before the next miss removes it. Values
    ///   below one are normalized to one, ensuring a single miss never clears a port.
    /// - Parameter maximumIncompletePortsPerKey: Maximum tentative ports learned
    ///   only from incomplete scans that may be retained for one key. Values below
    ///   one are normalized to one. Ports confirmed by a complete scan are not capped.
    public init(
        missingPortRetentionLimit: Int = 2,
        maximumIncompletePortsPerKey: Int = 256
    ) {
        self.missingPortRetentionLimit = max(1, missingPortRetentionLimit)
        self.maximumIncompletePortsPerKey = max(1, maximumIncompletePortsPerKey)
    }

    /// Applies a scan observation and returns the stable snapshot to publish.
    ///
    /// - Parameters:
    ///   - scannedPorts: Positively observed ports by tracked key. Missing keys
    ///     and empty arrays are negative evidence only for a complete scan.
    ///   - scannedKeys: Keys covered by this scan. Tracked keys outside this
    ///     scope are preserved without advancing their missing counts.
    ///   - trackedKeys: Keys that still belong to the scanner lifecycle.
    ///   - completeness: Whether missing observations are authoritative enough
    ///     to advance removal.
    /// - Returns: The reconciled stable snapshot.
    @discardableResult
    public mutating func reconcile(
        scannedPorts: [Key: [Int]],
        scannedKeys: Set<Key>,
        trackedKeys: Set<Key>,
        completeness: PortScanCompleteness
    ) -> [Key: [Int]] {
        reconcile(
            scannedPorts: scannedPorts,
            scannedKeys: scannedKeys,
            trackedKeys: trackedKeys,
            completenessByKey: Dictionary(
                uniqueKeysWithValues: scannedKeys.map { ($0, completeness) }
            )
        )
    }

    /// Applies scan observations with completeness scoped to each scanned key.
    ///
    /// - Parameters:
    ///   - scannedPorts: Positively observed ports by tracked key. Missing keys
    ///     and empty arrays are negative evidence only for a complete key.
    ///   - scannedKeys: Keys covered by this scan. Tracked keys outside this
    ///     scope are preserved without advancing their missing counts.
    ///   - trackedKeys: Keys that still belong to the scanner lifecycle.
    ///   - completenessByKey: Whether each key's missing observations are
    ///     authoritative enough to advance removal. Missing entries are treated
    ///     as incomplete.
    /// - Returns: The reconciled stable snapshot.
    @discardableResult
    public mutating func reconcile(
        scannedPorts: [Key: [Int]],
        scannedKeys: Set<Key>,
        trackedKeys: Set<Key>,
        completenessByKey: [Key: PortScanCompleteness]
    ) -> [Key: [Int]] {
        snapshot = snapshot.filter { trackedKeys.contains($0.key) }
        missingObservationCounts = missingObservationCounts.filter { trackedKeys.contains($0.key) }
        incompletePortsByKey = incompletePortsByKey.filter { trackedKeys.contains($0.key) }
        incompletePortObservationSequenceByKey = incompletePortObservationSequenceByKey.filter {
            trackedKeys.contains($0.key)
        }

        for key in scannedKeys.intersection(trackedKeys) {
            let observed = Set((scannedPorts[key] ?? []).filter { $0 > 0 && $0 <= 65_535 })
            let previous = Set(snapshot[key] ?? [])

            switch completenessByKey[key, default: .incomplete] {
            case .incomplete:
                let unbounded = previous.union(observed)
                var incompletePorts = incompletePortsByKey[key] ?? []
                incompletePorts.formUnion(observed.subtracting(previous))
                incompletePorts.formIntersection(unbounded)
                var observationSequences = incompletePortObservationSequenceByKey[key] ?? [:]
                for port in observed.intersection(incompletePorts).sorted() {
                    observationSequence &+= 1
                    observationSequences[port] = observationSequence
                }
                let retainedIncompletePorts = Set(incompletePorts.sorted { lhs, rhs in
                    let lhsSequence = observationSequences[lhs, default: 0]
                    let rhsSequence = observationSequences[rhs, default: 0]
                    return lhsSequence == rhsSequence ? lhs < rhs : lhsSequence > rhsSequence
                }.prefix(maximumIncompletePortsPerKey))
                let retained = unbounded.subtracting(incompletePorts.subtracting(retainedIncompletePorts))
                if retained.isEmpty {
                    snapshot.removeValue(forKey: key)
                } else {
                    snapshot[key] = retained.sorted()
                }
                storeIncompletePorts(
                    retainedIncompletePorts,
                    observationSequences: observationSequences,
                    for: key
                )
                var counts = (missingObservationCounts[key] ?? [:]).filter {
                    retained.contains($0.key)
                }
                for port in observed {
                    counts.removeValue(forKey: port)
                }
                if counts.isEmpty {
                    missingObservationCounts.removeValue(forKey: key)
                } else {
                    missingObservationCounts[key] = counts
                }

            case .complete:
                var retained = observed
                var nextCounts: [Int: Int] = [:]
                for port in previous.subtracting(observed) {
                    let missCount = (missingObservationCounts[key]?[port] ?? 0) + 1
                    if missCount <= missingPortRetentionLimit {
                        retained.insert(port)
                        nextCounts[port] = missCount
                    }
                }
                if retained.isEmpty {
                    snapshot.removeValue(forKey: key)
                } else {
                    snapshot[key] = retained.sorted()
                }
                if nextCounts.isEmpty {
                    missingObservationCounts.removeValue(forKey: key)
                } else {
                    missingObservationCounts[key] = nextCounts
                }
                var incompletePorts = incompletePortsByKey[key] ?? []
                incompletePorts.subtract(observed)
                incompletePorts.formIntersection(retained)
                storeIncompletePorts(
                    incompletePorts,
                    observationSequences: incompletePortObservationSequenceByKey[key] ?? [:],
                    for: key
                )
            }
        }

        return snapshot
    }

    /// Immediately removes keys whose scanner lifecycle ended.
    ///
    /// - Parameter keys: Keys that are no longer tracked.
    public mutating func remove(keys: Set<Key>) {
        for key in keys {
            snapshot.removeValue(forKey: key)
            missingObservationCounts.removeValue(forKey: key)
            incompletePortsByKey.removeValue(forKey: key)
            incompletePortObservationSequenceByKey.removeValue(forKey: key)
        }
    }

    /// Clears all published ports and reconciliation history.
    public mutating func reset() {
        snapshot.removeAll()
        missingObservationCounts.removeAll()
        incompletePortsByKey.removeAll()
        incompletePortObservationSequenceByKey.removeAll()
        observationSequence = 0
    }

    private mutating func storeIncompletePorts(
        _ ports: Set<Int>,
        observationSequences: [Int: UInt64],
        for key: Key
    ) {
        guard !ports.isEmpty else {
            incompletePortsByKey.removeValue(forKey: key)
            incompletePortObservationSequenceByKey.removeValue(forKey: key)
            return
        }
        incompletePortsByKey[key] = ports
        incompletePortObservationSequenceByKey[key] = observationSequences.filter { ports.contains($0.key) }
    }
}
