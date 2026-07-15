import CmuxFoundation
import Foundation

/// Simulates a successful Git invocation whose captured output is not valid UTF-8.
actor UndecodableWorktreeIncludeCommandRunner: OutputLimitedCommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data?,
        maximumOutputBytes: Int?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: nil,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
