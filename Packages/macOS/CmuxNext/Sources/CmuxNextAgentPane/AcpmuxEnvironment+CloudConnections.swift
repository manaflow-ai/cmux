public import CmuxNextCloud
public import Foundation

extension AcpmuxEnvironment {
    /// This Mac's connections in order (`_acpmux/connections`, cmux-tui/docs/model-connections.md), for
    /// Cloud first use (``CloudSetup``); nil when no daemon answers or it predates the method. Never
    /// starts a daemon.
    public nonisolated func cloudConnections(deadline: Duration? = .seconds(3)) async -> [CloudSetup.Connection]? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/connections", deadline: deadline),
              let rows = result["connections"] as? [[String: Any]] else { return nil }
        return rows.compactMap(CloudSetup.Connection.init(json:))
    }

    /// Reads a connection's launch credential as the person. Only a typed refusal
    /// reason crosses to the UI when acpmux denies the read.
    @MainActor public func connectionCredential(id: String, model: String? = nil) async throws -> Data {
        guard let line = await AcpmuxPersonLine.open(self) else {
            throw CloudAgentCredentials.Failure.unavailable(connection: id)
        }
        defer { line.close() }
        var params = ["id": id]
        params["model"] = model
        guard line.isPerson else { throw CloudAgentCredentials.Failure.unavailable(connection: id) }
        guard let reply = await line.call("_acpmux/connections/credential", params) else {
            if let reason = line.lastErrorReason {
                throw CloudAgentCredentials.Failure.refused(reason: reason)
            }
            throw CloudAgentCredentials.Failure.unavailable(connection: id)
        }
        return try JSONSerialization.data(withJSONObject: reply)
    }
}

extension AcpmuxHost {
    /// Joins the Settings startup path and gives readiness plus the connection read five seconds
    /// together. Cancellation ends only this caller's wait on shared daemon startup.
    public func readyCloudConnections() async -> [CloudSetup.Connection]? {
        try? await withAgentPaneDeadline(.seconds(5), label: "cloud connections") {
            let environment = try await self.readyEnvironment()
            return await environment.cloudConnections(deadline: nil)
        }
    }
}
