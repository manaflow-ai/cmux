/// The captured outcome of one multi-window route call through the bundled
/// cmux CLI.
///
/// Produced by ``MultiWindowRouting/route(arguments:)``. The fields mirror the
/// legacy AppDelegate capture exactly: `status` is the process termination
/// status rendered as a string (or `"-1"` when the CLI failed to launch), and
/// the streams are UTF-8 decoded with non-decodable output collapsing to the
/// empty string. Consumers (the multi-window UI-test scaffolding) write these
/// strings verbatim into the shared test-data file.
public struct MultiWindowRouteResult: Sendable, Equatable {
    /// The CLI process termination status as a string, or `"-1"` when the
    /// process could not be launched.
    public let status: String
    /// The captured standard output, UTF-8 decoded; empty when absent or not
    /// valid UTF-8.
    public let stdout: String
    /// The captured standard error, UTF-8 decoded; empty when absent or not
    /// valid UTF-8. Carries the launch-error description when `status` is
    /// `"-1"`.
    public let stderr: String

    /// Creates a route result.
    /// - Parameters:
    ///   - status: The termination status string, or `"-1"` for launch failure.
    ///   - stdout: The captured standard output.
    ///   - stderr: The captured standard error.
    public init(status: String, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}
