public import CmuxNextAgentPane
public import CmuxNextDaemon
import Foundation

/// The app's local repository catalog bridge. Keeping the daemon request here leaves the app
/// composition root with only the service lifetime capture.
public enum CloudRepositoryLocalRunner {
    @MainActor
    public static func run(_ daemon: DaemonService) async throws -> Data {
        let value = try await daemon.perform("cloud.repo.local") { connection in
            try await connection.request(AgentPaneCloudRepositoryLocalRequest(), timeout: .seconds(30))
        }
        return try JSONEncoder().encode(value)
    }
}
