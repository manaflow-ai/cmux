import CmuxFoundation
@testable import CmuxWorktrees
import Foundation

actor WorktreeListCompatibilityHost: WorktreeExecutionHost {
    nonisolated let id = WorktreeHostID(rawValue: "list-compatibility")
    nonisolated let homeDirectory = "/home"

    private let nulExitStatus: Int32
    private let nulStderr: String
    private let lineOutput: String
    private var arguments: [[String]] = []

    init(nulExitStatus: Int32, nulStderr: String, lineOutput: String) {
        self.nulExitStatus = nulExitStatus
        self.nulStderr = nulStderr
        self.lineOutput = lineOutput
    }

    func isAvailable() async -> Bool {
        true
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        self.arguments.append(arguments)
        switch arguments {
        case ["worktree", "list", "--porcelain", "-z"]:
            return CommandResult(
                stdout: nil,
                stderr: nulStderr,
                exitStatus: nulExitStatus,
                timedOut: false,
                executionError: nil
            )
        case ["worktree", "list", "--porcelain"]:
            return CommandResult(
                stdout: lineOutput,
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        default:
            return CommandResult(
                stdout: nil,
                stderr: "unexpected command: \(arguments.joined(separator: " "))",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        }
    }

    func recordedArguments() -> [[String]] {
        arguments
    }
}
