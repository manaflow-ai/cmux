/// Which Codex record type a transcript's accounting came from.
///
/// Once usage records appear they replace the cumulative fallback, whose
/// lifetime total may have been inherited from a parent thread.
public enum ChatUsageCodexSource: Sendable, Equatable {
    /// No Codex usage seen yet.
    case none

    /// Per-response `token_usage_record` lines.
    case usageRecords

    /// The cumulative `total_token_usage` from `token_count` events, used
    /// when the transcript predates `token_usage_record`.
    case cumulativeEvents
}
