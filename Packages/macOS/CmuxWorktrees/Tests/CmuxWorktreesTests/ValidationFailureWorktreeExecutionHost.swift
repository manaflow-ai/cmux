import CmuxFoundation
@testable import CmuxWorktrees
import Foundation

actor ValidationFailureWorktreeExecutionHost: WorktreeExecutionHost {
    nonisolated let id = WorktreeHostID(rawValue: "validation-failure")
    nonisolated let homeDirectory = "/home"

    private let removalError: String
    private var arguments: [[String]] = []

    init(
        removalError: String = "fatal: validation failed, cannot remove working tree: working trees containing submodules cannot be moved or removed"
    ) {
        self.removalError = removalError
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
                stdout: """
                worktree /repo\0HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\0branch refs/heads/main\0\0worktree /repo/worktrees/feature\0HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0branch refs/heads/feature\0\0
                """,
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        case ["status", "--porcelain", "--untracked-files=normal"]:
            return CommandResult(
                stdout: "",
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        case ["worktree", "remove", "/repo/worktrees/feature"]:
            return CommandResult(
                stdout: nil,
                stderr: removalError,
                exitStatus: 128,
                timedOut: false,
                executionError: nil
            )
        case ["worktree", "prune", "--verbose"]:
            return CommandResult(
                stdout: "",
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
