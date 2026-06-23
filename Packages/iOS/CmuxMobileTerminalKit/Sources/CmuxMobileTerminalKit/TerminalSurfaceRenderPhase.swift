/// Render phase for the active terminal surface generation.
public enum TerminalSurfaceRenderPhase: Equatable, Sendable {
    /// No render is queued or executing.
    case idle
    /// A render is queued or executing.
    ///
    /// `startedAt` is `nil` while the render is only queued behind the
    /// surface executor, and non-nil once Ghostty execution begins.
    case inFlight(
        generation: UInt64,
        enqueuedAt: Double,
        startedAt: Double?,
        needsCoalescedRender: Bool
    )
    /// The generation exceeded its queued or executing render timeout.
    case stalled(generation: UInt64, startedAt: Double)
}
