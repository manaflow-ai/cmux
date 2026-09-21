import Foundation

/// Executes Cloud filesystem commands through the authenticated VM API.
struct LiveCloudFileExplorerCommandRunner: CloudFileExplorerCommandRunning {
    /// Runs a command through the authenticated Cloud VM control plane.
    func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult {
        guard let client = await MainActor.run(body: { VMClient.shared }) else {
            throw FileExplorerError.providerUnavailable
        }
        return try await client.exec(id: vmID, command: command, timeoutMs: timeoutMs)
    }
}
