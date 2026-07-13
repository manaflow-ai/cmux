import Foundation

/// A point-in-time view of an open render drop episode.
public struct TerminalRenderStallSnapshot: Sendable, Equatable {
    /// The surface the episode belongs to.
    public let surface: UInt32
    /// The gate currently dropping frames.
    public let gate: TerminalRenderDropGate
    /// Number of dropped frames observed in the episode.
    public let droppedFrames: Int
    /// How long the episode has been open.
    public let duration: TimeInterval
    /// Whether ``TerminalStallEmission/stallDetected(surface:gate:droppedFrames:stallDuration:)`` already emitted.
    public let stallDetected: Bool
}
