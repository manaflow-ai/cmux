import Foundation

/// Runs subprocesses with descendant-safe ownership and bounded output.
public struct SimulatorOwnedCommandRunner:
    SimulatorOwnedCommandRunning,
    Sendable
{
    private let boundedCommands: any SimulatorBoundedCommandRunning

    /// Creates a runner backed by the package's descendant-safe command runner.
    public init() {
        boundedCommands = SimulatorBoundedCommandRunner()
    }

    init(boundedCommands: any SimulatorBoundedCommandRunning) {
        self.boundedCommands = boundedCommands
    }

    /// Runs one executable in an owned process group with bounded output.
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int = 64 * 1_024
    ) async -> SimulatorOwnedCommandResult {
        let result = await boundedCommands.runBounded(
            directory: currentDirectory,
            executable: executable,
            arguments: arguments,
            environment: [:],
            timeout: timeout,
            standardOutputLimit: outputLimit,
            standardErrorLimit: outputLimit
        )
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
