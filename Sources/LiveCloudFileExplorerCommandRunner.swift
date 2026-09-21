import Foundation

/// Uses the existing VM API with the originating account/team pinned through token refresh.
struct LiveCloudFileExplorerCommandRunner: CloudFileExplorerCommandRunning {
    let target: CloudFileExplorerTarget?

    func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult {
        guard let target else { throw FileExplorerError.providerUnavailable }
        try await target.validate(vmID: vmID)
        guard let client = await MainActor.run(body: { VMClient.shared }) else {
            throw FileExplorerError.providerUnavailable
        }
        let result = try await client.exec(id: vmID, command: command, timeoutMs: timeoutMs,
                                           expectedTeamScope: target.identity.team)
        try Task.checkCancellation()
        try await target.validate(vmID: vmID)
        return result
    }
}
