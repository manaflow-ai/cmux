import Foundation
@testable import CmuxSimulator

actor RecordingSimulatorBoundedCommandRunner: SimulatorBoundedCommandRunning {
    let result: SimulatorBoundedCommandResult
    private(set) var request: SimulatorBoundedCommandRequest?

    init(result: SimulatorBoundedCommandResult) {
        self.result = result
    }

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        request = SimulatorBoundedCommandRequest(
            directory: directory,
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit
        )
        return result
    }
}
