import CmuxFoundation
import Foundation

/// Returns more worktree-include candidates than the service may retain.
actor OversizedWorktreeCandidateCommandRunner: StandardInputCommandRunning {
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
        standardInput: Data,
        timeout: TimeInterval?
    ) async -> CommandResult {
        successfulResult(stdout: "")
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
