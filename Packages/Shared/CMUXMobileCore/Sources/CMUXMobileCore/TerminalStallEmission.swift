import Foundation

/// A stall monitor emission that callers can record or upload.
public enum TerminalStallEmission: Sendable, Equatable {
    /// A drop episode crossed the configured stall threshold.
    case stallDetected(
        surface: UInt32,
        gate: TerminalRenderDropGate,
        droppedFrames: Int,
        stallDuration: TimeInterval
    )
    /// A previously detected stall episode resolved.
    case stallRecovered(
        surface: UInt32,
        gate: TerminalRenderDropGate,
        how: TerminalStallRecoveryCause,
        duration: TimeInterval,
        droppedFrames: Int
    )
}
