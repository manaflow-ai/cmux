/// The public snapshot plus private lookup metadata for its snapshot-scoped refs.
public struct SimulatorUIAutomationSnapshotRecord: Equatable, Sendable {
    /// The public compact snapshot.
    public let snapshot: SimulatorUIAutomationSnapshot
    /// Lookup metadata in snapshot traversal order.
    public let elementRecords: [SimulatorUIAutomationElementRecord]
    /// Lookup metadata keyed by element reference.
    public let elementsByRef: [String: SimulatorUIAutomationElementRecord]
    /// Display metadata captured with the source accessibility tree.
    public let display: SimulatorDisplayMetadata?

    /// Creates a snapshot record and its reference index.
    ///
    /// - Parameters:
    ///   - snapshot: The public compact snapshot.
    ///   - elementRecords: Lookup metadata in traversal order.
    ///   - display: Display metadata captured with the accessibility tree.
    public init(
        snapshot: SimulatorUIAutomationSnapshot,
        elementRecords: [SimulatorUIAutomationElementRecord],
        display: SimulatorDisplayMetadata? = nil
    ) {
        self.snapshot = snapshot
        self.elementRecords = elementRecords
        self.elementsByRef = Dictionary(
            elementRecords.map { ($0.element.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.display = display
    }

    /// Returns the lookup record for one current element reference.
    ///
    /// - Parameter ref: The snapshot-scoped reference.
    /// - Returns: The matching lookup record, or `nil` when absent.
    public func element(ref: String) -> SimulatorUIAutomationElementRecord? {
        elementsByRef[ref]
    }
}
