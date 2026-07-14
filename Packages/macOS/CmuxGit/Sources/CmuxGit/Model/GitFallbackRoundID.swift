public import Foundation

/// Identity of one process-wide five-minute git fallback tick.
public nonisolated struct GitFallbackRoundID: Equatable, Hashable, Sendable {
    /// Stable identity of the injected fallback coordinator.
    public let namespace: UUID
    /// Monotonic tick sequence within ``namespace``.
    public let sequence: UInt64

    /// Creates one explicit process-wide fallback round identity.
    public init(namespace: UUID, sequence: UInt64) {
        self.namespace = namespace
        self.sequence = sequence
    }
}
