public import Foundation

/// Runs commands while bounding each captured output stream.
///
/// Use this refinement for commands whose output size depends on repository or
/// user-controlled data. Conforming runners terminate the child once either
/// stdout or stderr exceeds the requested byte limit.
public protocol OutputLimitedCommandRunning: StandardInputCommandRunning {
    /// Runs a command with a maximum byte count for each captured output stream.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - maximumOutputBytes: The greatest number of bytes retained from each stream.
    ///   - timeout: A deadline in seconds, or `nil` to wait indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult

    /// Runs a command with stdin data and bounded captured output streams.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - standardInput: Bytes written to stdin before the pipe is closed.
    ///   - maximumOutputBytes: The greatest number of bytes retained from each stream.
    ///   - timeout: A deadline in seconds, or `nil` to wait indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult
}
