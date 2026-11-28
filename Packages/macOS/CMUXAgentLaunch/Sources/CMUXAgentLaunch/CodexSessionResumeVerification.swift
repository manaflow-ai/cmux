/// The result of checking Codex's durable stores for a resume identifier.
///
/// `unavailable` is deliberately distinct from `missing`: callers preserve a
/// verified binding when a database or filesystem snapshot cannot be read.
public enum CodexSessionResumeVerification: Equatable, Sendable {
    /// Codex owns a non-empty rollout with the exact requested identifier.
    case exists(CodexSessionResumeEvidence)
    /// The readable durable stores contain no matching rollout.
    case missing
    /// At least one required durable store could not be inspected safely.
    case unavailable
}
