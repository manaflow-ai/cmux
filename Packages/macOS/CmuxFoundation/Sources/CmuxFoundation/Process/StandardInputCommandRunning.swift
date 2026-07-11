public import Foundation

/// Runs commands that consume a bounded byte payload on standard input.
///
/// Use this refinement when a command's native streaming interface is required
/// for unambiguous path handling, such as NUL-delimited Git path records.
public protocol StandardInputCommandRunning: CommandRunning {
    /// Runs a command with `standardInput` connected to the child process's stdin.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - standardInput: Bytes written to stdin before the pipe is closed.
    ///   - timeout: A deadline in seconds, or `nil` to wait indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval?
    ) async -> CommandResult
}
