import CmuxFoundation
import Foundation

struct SimulatorLegacyBoundedCommandRunner: SimulatorBoundedCommandRunning, Sendable {
    let commands: any CommandRunning

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            return SimulatorBoundedCommandResult(
                standardOutput: Data(),
                standardError: Data(),
                outputWasTruncated: false,
                errorWasTruncated: false,
                exitStatus: nil,
                timedOut: false,
                executionError: String(
                    localized: "simulator.failure.commandOutputLimit",
                    defaultValue: "Simulator subprocess output limits must be nonnegative."
                )
            )
        }
        let result: CommandResult
        if environment.isEmpty {
            result = await commands.run(
                directory: directory,
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        } else {
            result = CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "The legacy command runner cannot pass a private environment."
            )
        }
        let output = capture(result.stdout, limit: standardOutputLimit)
        let error = capture(result.stderr, limit: standardErrorLimit)
        return SimulatorBoundedCommandResult(
            standardOutput: output.data,
            standardError: error.data,
            outputWasTruncated: output.truncated,
            errorWasTruncated: error.truncated,
            exitStatus: result.exitStatus,
            timedOut: result.timedOut,
            executionError: result.executionError
        )
    }

    private func capture(_ string: String?, limit: Int) -> SimulatorCapturedStream {
        let data = Data((string ?? "").utf8)
        return SimulatorCapturedStream(
            data: Data(data.prefix(limit)),
            truncated: data.count > limit
        )
    }
}
