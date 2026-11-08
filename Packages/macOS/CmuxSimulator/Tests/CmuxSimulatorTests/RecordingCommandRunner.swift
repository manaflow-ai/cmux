import CmuxFoundation
import Foundation
@testable import CmuxSimulator

actor RecordingCommandRunner: CommandRunning, SimulatorBoundedCommandRunning {
    private var results: [CommandResult]
    private var invocations: [RecordingCommandInvocation] = []
    private var boundedLimits: [(output: Int, error: Int)] = []

    init(results: [CommandResult] = []) {
        self.results = results
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(RecordingCommandInvocation(
            executable: executable,
            arguments: arguments,
            environment: [:],
            timeout: timeout
        ))
        return results.isEmpty ? successfulCommandResult("") : results.removeFirst()
    }

    func recordedInvocations() -> [RecordingCommandInvocation] { invocations }

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        boundedLimits.append((standardOutputLimit, standardErrorLimit))
        invocations.append(RecordingCommandInvocation(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        ))
        let result = results.isEmpty ? successfulCommandResult("") : results.removeFirst()
        let output = captureCommandOutput(result.stdout, limit: standardOutputLimit)
        let error = captureCommandOutput(result.stderr, limit: standardErrorLimit)
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

    func recordedBoundedLimits() -> [(output: Int, error: Int)] { boundedLimits }
}

private func captureCommandOutput(
    _ value: String?,
    limit: Int
) -> (data: Data, truncated: Bool) {
    let bytes = Data((value ?? "").utf8)
    return (Data(bytes.prefix(limit)), bytes.count > limit)
}

private func successfulCommandResult(_ stdout: String) -> CommandResult {
    CommandResult(
        stdout: stdout,
        stderr: "",
        exitStatus: 0,
        timedOut: false,
        executionError: nil
    )
}
