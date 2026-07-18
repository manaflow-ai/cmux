public import Foundation

/// Proof that a renderer finished writing an IOSurface before publishing it.
public enum TerminalRenderCompletionFence: Equatable, Sendable {
    /// The frame was sent from the producer's GPU-completion callback. No
    /// cross-process wait is necessary before the consumer reads the surface.
    case producerCompleted

    /// The consumer must wait for an out-of-band shared Metal event.
    case sharedEvent(eventID: UUID, value: UInt64)

}
