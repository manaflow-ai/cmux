public import CmuxNextCloud
public import Foundation

extension AcpmuxEnvironment {
    /// This Mac's connections in order (`_acpmux/connections`, cmux-tui/docs/model-connections.md), for
    /// Cloud first use (``CloudSetup``); nil when no daemon answers or it predates the method. Never
    /// starts a daemon.
    public nonisolated func cloudConnections(deadline: Duration = .seconds(3)) async -> [CloudSetup.Connection]? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/connections", deadline: deadline),
              let rows = result["connections"] as? [[String: Any]] else { return nil }
        return rows.compactMap(CloudSetup.Connection.init(json:))
    }

    /// Connection `id`'s credential as acpmux answers it (`_acpmux/connections/credential {id}`, asked as
    /// the person; model-connections.md Revision 2): the reply's JSON, or nil when no acpmux answers, the
    /// person proof is refused, or acpmux refuses the read. Read for one Cloud agent launch and dropped.
    @MainActor public func connectionCredential(id: String) async -> Data? {
        guard let line = await AcpmuxPersonLine.open(self) else { return nil }
        defer { line.close() }
        guard line.isPerson, let reply = await line.call("_acpmux/connections/credential", ["id": id]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: reply)
    }
}
