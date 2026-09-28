/// Which Codex record type a transcript's accounting came from.
///
/// Exists so a caller can tell a precise per-response total from the coarser
/// cumulative fallback, and so one provider's exact figure is never compared
/// to another's estimate without knowing which is which.
public enum ChatUsageCodexSource: Sendable, Equatable {
    /// No Codex usage seen yet.
    case none

    /// Per-response `token_usage_record` lines. Once these appear the
    /// cumulative events are ignored, including any prefix before the first
    /// record: a cumulative figure is a thread total that outlives a fork or
    /// a compaction, so it is not this transcript's spend.
    case usageRecords

    /// The cumulative `total_token_usage` from `token_count` events, used
    /// when the transcript predates `token_usage_record`.
    case cumulativeEvents
}
