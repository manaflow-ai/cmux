import CmuxFoundation
import Foundation
@testable import CmuxSimulator

actor LocationLifecycleCommandRunner: CommandRunning {
    private var recordedArguments: [[String]] = []
    private let failureInvocationIndices: Set<Int>

    init(failureInvocationIndices: Set<Int> = []) {
        self.failureInvocationIndices = failureInvocationIndices
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let invocationIndex = recordedArguments.count
        recordedArguments.append(arguments)
        if failureInvocationIndices.contains(invocationIndex) {
            return CommandResult(
                stdout: "",
                stderr: "injected location failure",
                exitStatus: 1,
                timedOut: false,
                executionError: nil
            )
        }
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
