import Foundation

/// The next operation selected by ``MobileBrowserStreamPacing``.
public enum MobileBrowserStreamPacingDecision: Equatable, Sendable {
    /// Capture an active JPEG for the supplied dirty generation.
    case captureJPEG(dirtyGeneration: UInt64)
    /// Capture a settled PNG for the supplied dirty generation.
    case capturePNG(dirtyGeneration: UInt64)
    /// Wait this many seconds before reconsidering.
    case wait(TimeInterval)
    /// Wait for an acknowledgement because the unacked window is full.
    case flowControlled
    /// No capture or deadline is pending.
    case idle
}
