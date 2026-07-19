/// The reason a Codex transcript monitor classified a turn as failed.
public enum CodexTranscriptMonitorFailureKind: Sendable, Equatable {
    /// Codex wrote an explicit error or stream-error payload.
    case reported

    /// Codex completed the turn without an error payload or final response.
    case missingFinalResponse
}
