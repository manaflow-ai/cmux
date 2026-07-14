public import Foundation

/// The `simctl` process seam.
///
/// Everything in this package that talks to CoreSimulator does so through this
/// protocol, so tests inject a fake that replays canned outputs and records the
/// exact invocations (see `RecordingSimctlRunner` in the test target). The
/// production conformance is ``SimctlCommandRunner``.
public protocol SimctlCommandRunning: Sendable {
    /// Runs `xcrun simctl <arguments>` and returns its stdout.
    ///
    /// - Parameter arguments: The `simctl` subcommand and its arguments,
    ///   e.g. `["list", "devices", "--json"]`.
    /// - Returns: The process's stdout on exit status 0.
    /// - Throws: ``SimctlCommandFailure`` for a non-zero exit, or the
    ///   underlying spawn error when the process cannot launch.
    @discardableResult
    func run(_ arguments: [String]) async throws -> Data
}
