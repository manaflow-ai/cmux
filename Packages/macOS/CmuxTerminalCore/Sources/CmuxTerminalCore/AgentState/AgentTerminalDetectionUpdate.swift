public import Foundation

/// One effective state change published by the bounded scheduler.
public struct AgentTerminalDetectionUpdate: Sendable, Equatable {
    /// The terminal surface receiving the change.
    public let surfaceID: UUID
    /// The terminal evidence revision that was classified.
    public let revision: UInt64
    /// The generation-safe semantic classification.
    public let classification: AgentTerminalStateClassification

    /// Creates an effective scheduler update.
    public init(surfaceID: UUID, revision: UInt64, classification: AgentTerminalStateClassification) {
        self.surfaceID = surfaceID
        self.revision = revision
        self.classification = classification
    }
}
