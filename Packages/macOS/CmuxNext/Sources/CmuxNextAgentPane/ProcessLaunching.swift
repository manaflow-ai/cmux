public import Foundation

/// Starts a process (``AcpmuxReplySender``'s seam; tests pass a fake).
public protocol ProcessLaunching: Sendable {
    /// Starts `executable` with `arguments` and `environment`.
    ///
    /// - Returns: True when the process started.
    nonisolated func launch(_ executable: URL, arguments: [String], environment: [String: String]) -> Bool
}
