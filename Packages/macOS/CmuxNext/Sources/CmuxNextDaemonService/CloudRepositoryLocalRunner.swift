public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// The app's local repository catalog bridge. Keeping the daemon request here leaves the app
/// composition root with only the service lifetime capture.
extension DaemonService {
    @MainActor
    public func cloudRepositoryLocal() async throws -> Data {
        let value = try await perform("cloud.repo.local") { connection in
            try await connection.request(AgentPaneCloudRepositoryLocalRequest(), timeout: .seconds(30))
        }
        return try JSONEncoder().encode(value)
    }
}
