import Foundation

/// Result of a subprocess launched in a dedicated, parent-supervised process group.
public struct SimulatorOwnedCommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardError: String
    public let timedOut: Bool
}

/// Synchronous bridge for CLI commands that need the Simulator package's
/// descendant-safe process ownership and bounded pipe draining.
public enum SimulatorOwnedCommandRunner {
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int = 64 * 1_024
    ) -> SimulatorOwnedCommandResult {
        let resultBox = SimulatorOwnedCommandResultBox()
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let result = await SimulatorBoundedCommandRunner().runBounded(
                directory: currentDirectory,
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                standardOutputLimit: outputLimit,
                standardErrorLimit: outputLimit
            )
            resultBox.set(result)
            finished.signal()
        }

        // The async runner owns its process group and has a one-second final
        // teardown deadline. This outer deadline prevents a bridge regression
        // from blocking the synchronous CLI forever.
        guard finished.wait(timeout: .now() + max(0, timeout) + 2) == .success,
              let result = resultBox.get() else {
            task.cancel()
            return SimulatorOwnedCommandResult(
                status: 124,
                standardError: String(
                    localized: "simulator.failure.commandTimedOut",
                    defaultValue: "The Simulator command timed out."
                ),
                timedOut: true
            )
        }
        let error = result.executionError
            ?? String(data: result.standardError, encoding: .utf8)
            ?? ""
        return SimulatorOwnedCommandResult(
            status: result.timedOut ? 124 : (result.exitStatus ?? 1),
            standardError: error,
            timedOut: result.timedOut
        )
    }
}

private final class SimulatorOwnedCommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SimulatorBoundedCommandResult?

    func set(_ result: SimulatorBoundedCommandResult) {
        lock.withLock { self.result = result }
    }

    func get() -> SimulatorBoundedCommandResult? {
        lock.withLock { result }
    }
}
