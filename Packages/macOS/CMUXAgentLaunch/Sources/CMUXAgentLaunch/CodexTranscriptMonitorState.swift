/// The terminal state observed for one Codex turn.
public enum CodexTranscriptMonitorState: Sendable, Equatable {
    /// The transcript does not yet contain a terminal result.
    case pending

    /// The transcript contains a successful terminal result or assistant response.
    case healthy

    /// The transcript contains a terminal or immediately publishable failure.
    case failure(CodexTranscriptMonitorFailure)
}
