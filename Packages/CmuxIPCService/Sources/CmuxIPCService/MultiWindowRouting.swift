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
    /// - Returns: The ``MultiWindowRouteResult`` describing how the CLI call
    ///   finished, including the legacy `"-1"` launch-failure encoding.
    func route(arguments: [String]) -> MultiWindowRouteResult
}
