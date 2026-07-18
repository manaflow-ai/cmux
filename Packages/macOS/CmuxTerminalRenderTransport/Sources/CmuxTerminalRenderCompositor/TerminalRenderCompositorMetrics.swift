/// Bounded compositor counters suitable for performance assertions.
public struct TerminalRenderCompositorMetrics: Equatable, Sendable {
    /// Frames admitted by the final presentation fence.
    public internal(set) var admittedFrames: UInt64 = 0

    /// Full IOSurface-to-drawable blits committed by the Swift host.
    public internal(set) var submittedBlits: UInt64 = 0

    /// Admitted frames discarded in favor of a newer pending frame.
    public internal(set) var coalescedFrames: UInt64 = 0

    /// Frames rejected before Metal import or command submission.
    public internal(set) var rejectedFrames: UInt64 = 0

    /// Creates zeroed counters.
    public init() {}
}
