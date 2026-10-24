public import Foundation

/// Runs a process to its end (``AcpmuxReplySender``'s seam; tests pass a fake).
public protocol ProcessLaunching: Sendable {
    /// Runs `executable` with `arguments` and `environment` until it exits or passes the launcher's
    /// deadline (it is then killed).
    ///
    /// - Returns: The exit status; nil when the process did not start or passed its deadline.
    nonisolated func run(_ executable: URL, arguments: [String], environment: [String: String]) async -> Int32?
}
