/// The input boundary matched to one agent prompt-submission hook.
public enum PromptSubmissionConfirmationOrigin: Equatable, Sendable {
    /// An input boundary submitted by the human.
    case human
    /// An app-owned transaction and its remaining hook-recording policy.
    case programmatic(ProgrammaticPromptHookRecording)
    /// No safely ordered boundary was available.
    case unmatched
}
