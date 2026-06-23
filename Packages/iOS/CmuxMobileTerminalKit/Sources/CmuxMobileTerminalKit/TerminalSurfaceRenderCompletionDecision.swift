/// Result of completing a render for a terminal surface generation.
public enum TerminalSurfaceRenderCompletionDecision: Equatable, Sendable {
    /// The completion belongs to an abandoned or otherwise non-current generation.
    case ignoredStaleCompletion
    /// The render completed and no further render is queued.
    case idle
    /// A render was coalesced while this render was pending, so the caller should enqueue one more frame.
    case enqueueCoalesced
}
