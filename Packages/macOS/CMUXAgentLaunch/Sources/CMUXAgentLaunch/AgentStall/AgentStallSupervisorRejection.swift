/// Fail-closed reasons why a stall observation does not produce an action.
public enum AgentStallSupervisorRejection: Equatable, Sendable {
    /// No known provider banner was observed.
    case unknownClassification
    /// The pane is not owned by a managed agent lifecycle.
    case unmanagedSession
    /// Provider/session identity is not complete enough to prove ownership.
    case incompleteSession
    /// The classification belongs to a different provider than the binding.
    case providerMismatch
    /// The output belongs to an older command generation.
    case staleGeneration
    /// The shell has not proven that the prompt is idle.
    case notIdle
    /// The managed process was confirmed to have exited.
    case processExited
    /// The managed process could not be proven alive.
    case processUnknown
    /// The provider binding is missing or no longer identifies this session.
    case invalidBinding
    /// The user explicitly interrupted or exited.
    case userInterrupted
    /// The turn completed without an error banner.
    case normalCompletion
    /// Automatic retry is disabled for a retryable cause.
    case disabled
    /// The matched retry rule did not provide a provider action identifier.
    case missingRetryAction
    /// The retry budget has been consumed.
    case exhausted
}
