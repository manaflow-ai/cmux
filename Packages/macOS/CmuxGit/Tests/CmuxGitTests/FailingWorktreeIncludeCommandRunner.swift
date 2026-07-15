import CmuxFoundation
import Foundation

/// Times out every standard-ignore directory batch and records how many were attempted.
actor FailingWorktreeIncludeCommandRunner: OutputLimitedCommandRunning {
    private var standardIgnoreCalls = 0
    private let initialCandidates = (0..<300).map { "cache-\($0)/\0" }.joined()

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data?,
        maximumOutputBytes: Int?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        if standardInput != nil {
            return success(stdout: "")
        }
        if arguments.contains("--exclude-standard") {
            standardIgnoreCalls += 1
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        }
        return success(stdout: arguments.contains("--directory") ? initialCandidates : "")
    }

    func standardIgnoreCallCount() -> Int {
        standardIgnoreCalls
    }

    private func success(stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
