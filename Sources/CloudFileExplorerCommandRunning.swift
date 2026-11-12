import CmuxCloud
import Foundation

/// Runs one authenticated command on a Cloud VM.
protocol CloudFileExplorerCommandRunning: Sendable {
    nonisolated func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult
}
