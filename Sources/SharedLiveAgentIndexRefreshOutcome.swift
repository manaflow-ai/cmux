import Foundation

/// Result of an ownership-sensitive refresh of ``SharedLiveAgentIndex``.
///
/// Restore admission needs an index from a scan that started after the
/// request was made. The refresh fails closed only when no such scan can
/// finish inside the admission deadline or the requesting task is cancelled,
/// and it names the reason so callers can explain the failure instead of
/// reporting a generic "could not verify".
enum SharedLiveAgentIndexRefreshOutcome: Sendable {
    /// A scan that observed the hook stores after the request completed.
    case index(RestorableAgentSessionIndex)
    /// No qualifying scan finished before the ownership refresh deadline.
    case timedOut
    /// The requesting task was cancelled while it waited for the scan.
    case cancelled
}
