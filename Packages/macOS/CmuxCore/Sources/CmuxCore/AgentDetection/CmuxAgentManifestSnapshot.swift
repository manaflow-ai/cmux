/// An immutable, accepted manifest catalog generation.
public struct CmuxAgentManifestSnapshot: Equatable, Sendable {
    /// Validated entries in deterministic catalog order.
    public let entries: [CmuxAgentManifestEntry]
    /// Monotonically increasing generation assigned by the live store.
    public let generation: UInt64

    /// Creates an immutable catalog snapshot.
    public init(entries: [CmuxAgentManifestEntry], generation: UInt64 = 0) {
        self.entries = entries
        self.generation = generation
    }

    /// Builds a pure evaluator over this snapshot.
    public var engine: CmuxAgentDetectionEngine {
        CmuxAgentDetectionEngine(entries: entries)
    }

    /// Returns the accepted entry with the requested id.
    public func entry(id: String) -> CmuxAgentManifestEntry? {
        entries.first { $0.manifest.id == id }
    }
}
