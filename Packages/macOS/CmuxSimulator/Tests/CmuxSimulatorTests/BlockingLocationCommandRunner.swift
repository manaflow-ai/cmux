import CmuxFoundation
import Foundation
@testable import CmuxSimulator

actor BlockingLocationCommandRunner: CommandRunning {
    private var recordedArguments: [[String]] = []
    private var firstCommandContinuation: CheckedContinuation<Void, Never>?
    private var invocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedArguments.append(arguments)
        let count = recordedArguments.count
        let ready = invocationWaiters.filter { $0.0 <= count }
        invocationWaiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        if count == 1 {
            await withCheckedContinuation { firstCommandContinuation = $0 }
        }
        return CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func waitForInvocationCount(_ count: Int) async {
        guard recordedArguments.count < count else { return }
        await withCheckedContinuation { invocationWaiters.append((count, $0)) }
    }

    func releaseFirstCommand() {
        firstCommandContinuation?.resume()
        firstCommandContinuation = nil
    }

    func arguments() -> [[String]] { recordedArguments }
}
