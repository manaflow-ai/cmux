import CmuxFoundation
import Foundation

struct FakeCommandRunner: CommandRunning {
    let response: @Sendable (_ directory: String, _ arguments: [String]) -> CommandResult

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        response(directory, arguments)
    }

    static func failure(_ diagnostic: String) -> FakeCommandRunner {
        FakeCommandRunner { _, _ in
            CommandResult(
                stdout: nil,
                stderr: diagnostic,
                exitStatus: 128,
                timedOut: false,
                executionError: nil
            )
        }
    }
}
