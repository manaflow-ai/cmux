public import Foundation

/// The exact Feed-owned attention overlay that a later conclusion may remove.
public nonisolated struct AgentFeedAttentionToken: Hashable, Sendable {
    /// The unique overlay identity.
    public let id: UUID
    /// The process generation that owned the overlay, when known.
    public let processGeneration: AgentProcessGeneration?

    /// Creates a Feed-attention token.
    ///
    /// - Parameters:
    ///   - id: A unique overlay identifier. A random UUID is used by default.
    ///   - processGeneration: The owning process generation, when known.
    public init(
        id: UUID = UUID(),
        processGeneration: AgentProcessGeneration?
    ) {
        self.id = id
        self.processGeneration = processGeneration
    }
}
