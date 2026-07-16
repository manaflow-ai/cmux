import CmuxFoundation
import Foundation

actor RecordingPullRequestCommandRunner: CommandRunning {
    private(set) var lastArguments: [String] = []
    private(set) var invocationArguments: [[String]] = []
    private var outputs: [String]

    init(outputs: [String] = []) {
        self.outputs = outputs
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = (directory, executable, timeout)
        lastArguments = arguments
        invocationArguments.append(arguments)
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        return CommandResult(
            stdout: output,
            stderr: nil,
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
