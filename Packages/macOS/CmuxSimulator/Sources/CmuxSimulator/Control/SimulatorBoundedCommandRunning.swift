import Foundation

protocol SimulatorBoundedCommandRunning: Sendable {
    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult
}
