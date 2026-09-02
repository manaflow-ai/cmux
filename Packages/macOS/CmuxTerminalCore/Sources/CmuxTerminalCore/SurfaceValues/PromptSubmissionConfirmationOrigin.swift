/// The input boundary matched to one agent prompt-submission hook.
public enum PromptSubmissionConfirmationOrigin: Equatable, Sendable {
    /// A human submission boundary confirmed by the agent hook.
    case human
    /// An app-owned transaction and the event source to record on confirmation.
    case programmatic(source: String)
    /// No safely attributable submission boundary matched the hook.
    case unmatched
    /// A duplicate hook matched an already-confirmed app-owned submission.
    case programmaticDuplicate
    /// An unmatched hook consumed a sequence-only app-owned boundary.
    case programmaticUnmatched
}
