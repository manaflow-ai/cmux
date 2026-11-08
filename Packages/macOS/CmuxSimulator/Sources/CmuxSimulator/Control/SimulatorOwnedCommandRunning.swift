import Foundation

/// An injectable asynchronous command seam for callers that need the Simulator
/// package's descendant-safe process ownership and bounded pipe draining.
public protocol SimulatorOwnedCommandRunning: Sendable {
    /// Runs one executable in an owned process group with bounded output.
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int
    ) async -> SimulatorOwnedCommandResult
}
