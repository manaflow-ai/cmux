/// Reconciles best-effort port scans into a stable published snapshot.
///
/// Positive observations are applied immediately. Incomplete scans never remove
/// ports, while complete scans must miss a previously observed port repeatedly
/// before it is removed. Explicitly untracked keys are removed immediately.
public struct PortScanSnapshotReconciler<Key: Hashable & Sendable>: Sendable {
    /// The stable ports currently safe to publish, keyed by scan scope.
    public private(set) var snapshot: [Key: [Int]] = [:]

    private let missingPortRetentionLimit: Int
    private var missingObservationCounts: [Key: [Int: Int]] = [:]

    /// Creates a reconciler.
    ///
    /// - Parameter missingPortRetentionLimit: The number of consecutive complete
    ///   scans that may miss a known port before the next miss removes it. Values
    ///   below one are normalized to one, ensuring a single miss never clears a port.
    public init(missingPortRetentionLimit: Int = 2) {
        self.missingPortRetentionLimit = max(1, missingPortRetentionLimit)
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
        snapshot = snapshot.filter { trackedKeys.contains($0.key) }
        missingObservationCounts = missingObservationCounts.filter { trackedKeys.contains($0.key) }

        for key in scannedKeys.intersection(trackedKeys) {
            let observed = Set((scannedPorts[key] ?? []).filter { $0 > 0 && $0 <= 65_535 })
            let previous = Set(snapshot[key] ?? [])

            switch completeness {
            case .incomplete:
                let retained = previous.union(observed)
                if retained.isEmpty {
                    snapshot.removeValue(forKey: key)
                } else {
                    snapshot[key] = retained.sorted()
                }
                var counts = missingObservationCounts[key] ?? [:]
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
        }
    }

    /// Clears all published ports and reconciliation history.
    public mutating func reset() {
        snapshot.removeAll()
        missingObservationCounts.removeAll()
    }
}
