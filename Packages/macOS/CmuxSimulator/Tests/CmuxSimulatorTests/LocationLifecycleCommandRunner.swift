import CmuxFoundation
import Foundation
@testable import CmuxSimulator

actor LocationLifecycleCommandRunner: CommandRunning {
    private var recordedArguments: [[String]] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedArguments.append(arguments)
        return CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func arguments() -> [[String]] { recordedArguments }
}
