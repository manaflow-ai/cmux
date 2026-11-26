/// The captured outcome of one multi-window route call through the bundled
/// cmux CLI.
///
/// Produced by ``MultiWindowRouting/route(arguments:)`` once the CLI process
/// launched and exited (a process that never launched throws
/// ``MultiWindowRouteLaunchError`` instead). The streams are UTF-8 decoded
/// with non-decodable output collapsing to the empty string, matching the
/// legacy AppDelegate capture exactly; consumers (the multi-window UI-test
/// scaffolding) write `String(terminationStatus)` and the streams verbatim
/// into the shared test-data file.
public struct MultiWindowRouteResult: Sendable, Equatable {
    /// The CLI process termination status.
    public let terminationStatus: Int32
    /// The captured standard output, UTF-8 decoded; empty when absent or not
    /// valid UTF-8.
    public let stdout: String
    /// The captured standard error, UTF-8 decoded; empty when absent or not
    /// valid UTF-8.
    public let stderr: String

    /// Creates a route result.
    /// - Parameters:
    ///   - terminationStatus: The CLI process termination status.
    ///   - stdout: The captured standard output.
    ///   - stderr: The captured standard error.
    public init(terminationStatus: Int32, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}
