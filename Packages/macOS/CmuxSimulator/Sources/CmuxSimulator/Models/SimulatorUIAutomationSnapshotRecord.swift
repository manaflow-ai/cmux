/// The public snapshot plus private lookup metadata for its process-scoped refs.
public struct SimulatorUIAutomationSnapshotRecord: Equatable, Sendable {
    /// The public compact snapshot.
    public let snapshot: SimulatorUIAutomationSnapshot
    /// Lookup metadata in snapshot traversal order.
    public let elementRecords: [SimulatorUIAutomationElementRecord]
    /// Lookup metadata keyed by element reference.
    public let elementsByRef: [String: SimulatorUIAutomationElementRecord]

    /// Creates a snapshot record and its reference index.
    ///
    /// - Parameters:
    ///   - snapshot: The public compact snapshot.
    ///   - elementRecords: Lookup metadata in traversal order.
    public init(
        snapshot: SimulatorUIAutomationSnapshot,
        elementRecords: [SimulatorUIAutomationElementRecord]
    ) {
        self.snapshot = snapshot
        self.elementRecords = elementRecords
        self.elementsByRef = Dictionary(
            uniqueKeysWithValues: elementRecords.map { ($0.element.ref, $0) }
        )
    }

    /// Returns the lookup record for one current element reference.
    ///
    /// - Parameter ref: The process-scoped reference.
    /// - Returns: The matching lookup record, or `nil` when absent.
    public func element(ref: String) -> SimulatorUIAutomationElementRecord? {
        elementsByRef[ref]
    }
}
