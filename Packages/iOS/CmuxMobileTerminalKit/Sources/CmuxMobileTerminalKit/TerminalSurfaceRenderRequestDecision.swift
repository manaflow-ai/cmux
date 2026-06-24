/// Result of asking a terminal surface session to schedule a render.
public enum TerminalSurfaceRenderRequestDecision: Equatable, Sendable {
    /// A render should be enqueued for the specified surface generation.
    case enqueue(generation: UInt64)
    /// A render is already pending or executing, so the caller only marked that another frame is needed.
    case coalesced
    /// Rendering is blocked because the current generation has already been classified as stalled.
    case blockedByStalledSurface
    /// Rendering is blocked until replay or live output reaches a rebuilt generation.
    case blockedUntilOutput
}
