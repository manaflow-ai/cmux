public import Foundation

extension AcpmuxEnvironment {
    /// One acpmux method that the compiled action catalog names (a catalog request row or an `op:`
    /// suggestion list, `CatalogRequestHandlers`), on a fresh connection to this daemon; the
    /// result as JSON data. The caller passes only catalog method names, never user config.
    /// A request to this machine's own daemon socket, on a fresh connection: one that has not answered in
    /// 10 s is hung, and the catalog row reports the error rather than holding the user's action.
    public nonisolated func catalogCall(_ method: String, params: [String: any Sendable],
                                        // timeout: a hung local daemon (above)
                                        deadline: Duration = .seconds(10)) async throws -> Data {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: method, params: params, deadline: deadline)
        return try JSONSerialization.data(withJSONObject: result)
    }
}
