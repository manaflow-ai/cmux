import CmuxFoundation
import Foundation

actor RecordingCommandRunner: CommandRunning {
    private let underlying = CommandRunner()
    private var recordedArguments: [[String]] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedArguments.append(arguments)
        return await underlying.run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    func arguments() -> [[String]] {
        recordedArguments
    }
}
