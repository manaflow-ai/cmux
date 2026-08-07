/// The authoritative mechanism an agent integration uses to detect approval waits.
public nonisolated enum AgentApprovalDetectionMechanism: Equatable, Sendable {
    /// The adapter emits a distinct permission event that cmux may surface.
    case dedicatedPermissionEvent

    /// Side-effecting tool starts conservatively imply a permission wait.
    case sideEffectingToolStartInference

    /// An adapter observes the agent's decision after native policy evaluation.
    case nativePostPolicyObserver

    /// The agent's own reviewer owns approval and cmux keeps its events as telemetry.
    case nativeApprovalReviewer
}
