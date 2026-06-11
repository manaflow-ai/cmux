/// Routes a cmux CLI request to a specific window over the app's control
/// socket and returns the captured outcome.
///
/// This is the seam for the multi-window CLI-over-socket capability extracted
/// from AppDelegate: production code uses ``MultiWindowRouter``, and tests
/// inject a fake conforming type so they never spawn the real CLI. The window
/// targeting itself is expressed in `arguments` (for example
/// `["list-workspaces", "--window", id]`); the conforming type supplies the
/// CLI binary, socket path, and child environment.
public protocol MultiWindowRouting: Sendable {
    /// Runs the bundled cmux CLI against the configured socket with `arguments`
    /// and captures its termination status and output.
    ///
    /// - Parameter arguments: The CLI arguments after the implicit
    ///   `--socket <path>` pair (subcommand, window targeting flags, output
    ///   format flags).
    /// - Returns: The ``MultiWindowRouteResult`` describing how the launched
    ///   CLI call finished.
    /// - Throws: ``MultiWindowRouteLaunchError`` when the CLI process could
    ///   not be launched; a launched CLI never throws, its outcome (including
    ///   non-zero exit) is the returned result.
    func route(arguments: [String]) async throws -> MultiWindowRouteResult
}

extension MultiWindowRouting {
    /// Routes one CLI call, encoding a launch failure into the result instead
    /// of throwing.
    ///
    /// This is the legacy capture encoding the pre-extraction AppDelegate
    /// helper produced and the multi-window UI-test data file still expects:
    /// a CLI that never launched yields termination status `-1` with the
    /// launch error's description in `stderr` (byte-identical to the old
    /// `String(describing:)` text via ``MultiWindowRouteLaunchError``'s
    /// `CustomStringConvertible`). Use it when every call in a batch must run
    /// regardless of earlier launch failures.
    ///
    /// - Parameter arguments: The CLI arguments after the implicit
    ///   `--socket <path>` pair.
    /// - Returns: The route result, with launch failure folded in as
    ///   termination status `-1`.
    public func routeCapturingLaunchFailure(arguments: [String]) async -> MultiWindowRouteResult {
        do {
            return try await route(arguments: arguments)
        } catch {
            return MultiWindowRouteResult(
                terminationStatus: -1,
                stdout: "",
                stderr: String(describing: error)
            )
        }
    }
}
