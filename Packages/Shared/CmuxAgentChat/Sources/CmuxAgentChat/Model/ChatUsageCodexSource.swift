/// Which Codex record type a transcript's accounting came from.
///
/// A usage-record result may include an unattributed cumulative baseline when
/// an older rollout changes formats partway through the transcript.
public enum ChatUsageCodexSource: Sendable, Equatable {
    /// No Codex usage seen yet.
    case none

    /// Per-response `token_usage_record` lines, possibly with a cumulative
    /// prefix retained as an unattributed baseline.
    case usageRecords

    /// The cumulative `total_token_usage` from `token_count` events, used
    /// when the transcript predates `token_usage_record`.
    case cumulativeEvents
}
