public import Foundation

/// Runs external commands off the main thread and returns their captured output.
///
/// This is the injection seam for subprocess execution: production code uses
/// ``CommandRunner``, and tests inject a fake conforming type so they never spawn
/// a real process. Inject a `any CommandRunning` at the call site rather than
/// reaching for a global runner.
///
/// ```swift
/// final class Probe {
///     private let commands: any CommandRunning
///     init(commands: any CommandRunning = CommandRunner()) { self.commands = commands }
/// }
/// ```
public protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments` in `directory` and captures its output.
    ///
    /// The call resolves `executable` against `PATH` (and the runner's fallback
    /// directories) when it is not an absolute path. Output is read concurrently
    /// so large streams cannot deadlock on a full pipe buffer.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name (resolved against `PATH`) or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - timeout: A deadline in seconds; when it elapses the process is
    ///     terminated and the result has ``CommandResult/timedOut`` set. `nil`
    ///     waits indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult
}

extension CommandRunning {
    /// Runs a command and returns its standard output only when it exited cleanly.
    ///
    /// - Returns: The captured standard output when the command launched, did not
    ///   time out, and exited with status `0`; otherwise `nil`.
    public func runStandardOutput(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async -> String? {
        let result = await run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            return nil
        }
        return result.stdout
    }
}
