import Foundation

/// Result of a subprocess launched in a dedicated, parent-supervised process group.
public struct SimulatorOwnedCommandResult: Sendable, Equatable {
    public let status: Int32
    public let standardError: String
    public let timedOut: Bool

    public init(
        status: Int32,
        standardError: String,
        timedOut: Bool
    ) {
        self.status = status
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

/// An injectable asynchronous command seam for callers that need the Simulator
/// package's descendant-safe process ownership and bounded pipe draining.
public protocol SimulatorOwnedCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int
    ) async -> SimulatorOwnedCommandResult
}

public struct SimulatorOwnedCommandRunner:
    SimulatorOwnedCommandRunning,
    Sendable
{
    private let boundedCommands: any SimulatorBoundedCommandRunning

    public init() {
        boundedCommands = SimulatorBoundedCommandRunner()
    }

    init(boundedCommands: any SimulatorBoundedCommandRunning) {
        self.boundedCommands = boundedCommands
    }

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
