public import Foundation

extension AcpmuxEnvironment {
    /// One acpmux method that the compiled action catalog names (a catalog request row or an `op:`
    /// suggestion list, `CatalogRequestHandlers`), on a fresh connection to this daemon; the
    /// result as JSON data. The caller passes only catalog method names, never user config.
    public nonisolated func catalogCall(_ method: String, params: [String: any Sendable],
                                        deadline: Duration = .seconds(10)) async throws -> Data { // timeout: one catalog action or suggestion list; a daemon that never answers fails that action with its error (or leaves the list empty), and nothing else waits on it
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: method, params: params, deadline: deadline)
        return try JSONSerialization.data(withJSONObject: result)
    }
}
