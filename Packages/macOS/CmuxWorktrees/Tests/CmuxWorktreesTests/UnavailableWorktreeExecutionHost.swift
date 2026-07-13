import CmuxFoundation
@testable import CmuxWorktrees
import Foundation

struct UnavailableWorktreeExecutionHost: WorktreeExecutionHost {
    let id = WorktreeHostID(rawValue: "unavailable")
    let homeDirectory = "/unavailable"

    func isAvailable() async -> Bool {
        false
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            executionError: "unavailable"
        )
    }
}
