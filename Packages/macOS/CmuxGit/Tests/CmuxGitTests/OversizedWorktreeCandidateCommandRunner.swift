import CmuxFoundation
import Foundation

/// Returns more worktree-include candidates than the service may retain.
actor OversizedWorktreeCandidateCommandRunner: OutputLimitedCommandRunning {
    private let candidateOutput = (0...10_000)
        .map { "cache-\($0)/" }
        .joined(separator: "\0") + "\0"

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let isInitialCandidateQuery = arguments.contains("--directory")
            && !arguments.contains("--exclude-standard")
        return successfulResult(stdout: isInitialCandidateQuery ? candidateOutput : "")
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult {
        await run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval?
    ) async -> CommandResult {
        successfulResult(stdout: "")
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data,
        maximumOutputBytes: Int,
        timeout: TimeInterval?
    ) async -> CommandResult {
        await run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    private func successfulResult(stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
