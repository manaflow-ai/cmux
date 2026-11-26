/// A shell command and its captured output; renders as a terminal card.
///
/// Produced when the agent runs a shell tool, or (in plain terminal
/// sessions) when the user's typed command and its output are segmented.
public struct ChatTerminalCapture: Sendable, Equatable, Codable {
    /// The command line as submitted to the shell.
    public let command: String

    /// Captured output (stdout and stderr interleaved), possibly truncated
    /// at the producing side.
    public let output: String?

    /// The command's exit code, when known.
    public let exitCode: Int?

    /// Wall-clock duration in seconds, when known.
    public let durationSeconds: Double?

    /// Whether the command is still running (no result observed yet).
    public let isRunning: Bool

    /// Creates a terminal capture.
    ///
    /// - Parameters:
    ///   - command: The command line as submitted.
    ///   - output: Captured output, possibly truncated.
    ///   - exitCode: Exit code when known.
    ///   - durationSeconds: Wall-clock duration when known.
    ///   - isRunning: Whether the command is still running.
    public init(
        command: String,
        output: String? = nil,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRunning: Bool = false
    ) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.isRunning = isRunning
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case output
        case exitCode = "exit_code"
        case durationSeconds = "duration_seconds"
        case isRunning = "is_running"
    }
}
