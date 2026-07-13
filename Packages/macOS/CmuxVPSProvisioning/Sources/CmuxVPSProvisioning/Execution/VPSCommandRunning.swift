public import Foundation

/// Seam for running local processes (ssh/scp), injected so planner/executor
/// tests never spawn real processes.
public protocol VPSCommandRunning: Sendable {
    /// Runs `executable` with `arguments`, waiting up to `timeout` seconds.
    ///
    /// - Parameters:
    ///   - executable: Absolute executable path.
    ///   - arguments: Process arguments.
    ///   - environment: Full environment for the child, or `nil` to inherit.
    ///   - timeout: Wall-clock limit in seconds; on expiry the process is
    ///     terminated and an error is thrown.
    /// - Returns: Exit status plus captured stdout/stderr.
    /// - Throws: When the process cannot launch or times out.
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> VPSCommandResult
}
