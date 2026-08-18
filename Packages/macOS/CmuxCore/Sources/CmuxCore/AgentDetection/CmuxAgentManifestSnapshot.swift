/// An immutable, accepted manifest catalog generation.
public struct CmuxAgentManifestSnapshot: Equatable, Sendable {
    /// Validated entries in deterministic catalog order.
    public let entries: [CmuxAgentManifestEntry]
    /// Monotonically increasing generation assigned by the live store.
    public let generation: UInt64
    private let compiledEngine: CmuxAgentDetectionEngine

    /// Creates an immutable catalog snapshot.
    public init(entries: [CmuxAgentManifestEntry], generation: UInt64 = 0) {
        self.entries = entries
        self.generation = generation
        self.compiledEngine = CmuxAgentDetectionEngine(entries: entries)
    }

    /// Returns the evaluator compiled when this snapshot was accepted.
    public var engine: CmuxAgentDetectionEngine {
        compiledEngine
    }

    /// Returns the accepted entry with the requested id.
    public func entry(id: String) -> CmuxAgentManifestEntry? {
        entries.first { $0.manifest.id == id }
    }

    /// Snapshot equality intentionally compares source values rather than the
    /// compiled execution-plan object they deterministically produce.
    ///
    /// - Parameters:
    ///   - lhs: Snapshot on the left side of the comparison.
    ///   - rhs: Snapshot on the right side of the comparison.
    /// - Returns: `true` when entries and generation are equal.
    public static func == (
        lhs: CmuxAgentManifestSnapshot,
        rhs: CmuxAgentManifestSnapshot
    ) -> Bool {
        lhs.entries == rhs.entries && lhs.generation == rhs.generation
    }
}
