public import CmuxNextCloud
import Foundation

extension AcpmuxEnvironment {
    /// This Mac's connections in order (`_acpmux/connections`, cmux-tui/docs/model-connections.md), for
    /// Cloud first use (``CloudSetup``); nil when no daemon answers or it predates the method. Never
    /// starts a daemon.
    public nonisolated func cloudConnections(deadline: Duration = .seconds(3)) async -> [CloudSetup.Connection]? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/connections", deadline: deadline),
              let rows = result["connections"] as? [[String: Any]] else { return nil }
        return rows.compactMap(CloudSetup.Connection.init(json:))
    }
}
