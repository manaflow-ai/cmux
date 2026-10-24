import Foundation

/// Starts a process (``FeedReportReplies``'s seam).
protocol ProcessLaunching: Sendable {
    /// Starts `executable` with `arguments` and `environment`; true when it started.
    nonisolated func launch(_ executable: URL, arguments: [String], environment: [String: String]) -> Bool
}
