/// Decision produced by the render-stall detector.
public enum TerminalSurfaceRecoveryDecision: Equatable, Sendable {
    /// No recovery action is required.
    case none
    /// The current stalled generation should be abandoned and replaced with a new surface generation.
    case abandonAndRebuild(stalledGeneration: UInt64)
    /// Recovery budget is exhausted; keep the last known presentation instead of rebuilding again.
    case failClosed(stalledGeneration: UInt64)
}
