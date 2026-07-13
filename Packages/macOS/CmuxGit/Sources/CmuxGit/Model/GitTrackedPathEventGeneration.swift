public import Foundation

/// A caller-owned tracked-path event generation scoped to one cache owner.
///
/// `GitMetadataService` uses this value to decide when it may reuse a tracked
/// changes snapshot. The namespace separates independent owners whose numeric
/// generation counters can legitimately have the same value.
public nonisolated struct GitTrackedPathEventGeneration: Equatable, Hashable, Sendable {
    /// Stable identity for the owner that produced ``generation``.
    public let namespace: UUID
    /// Monotonic value that changes when the owner's watched git paths emit an event.
    public let generation: UInt64

    /// Creates a namespaced tracked-path event generation.
    ///
    /// - Parameters:
    ///   - namespace: Stable identity for the owner of this generation counter.
    ///   - generation: Monotonic value that changes after tracked-path events.
    public init(namespace: UUID, generation: UInt64) {
        self.namespace = namespace
        self.generation = generation
    }
}
