public import Foundation

/// Runs a process to its end (``AcpmuxReplySender``'s seam; tests pass a fake).
public protocol ProcessLaunching: Sendable {
    /// Runs `executable` with `arguments` and `environment` until it exits or passes the launcher's
    /// deadline (it is then killed).
    ///
    /// - Parameter input: Bytes for the child's standard input, which then closes; nil gives it the
    ///   null device.
    /// - Returns: The exit status; nil when the process did not start or passed its deadline.
    nonisolated func run(_ executable: URL, arguments: [String], environment: [String: String], input: Data?) async -> Int32?
}
