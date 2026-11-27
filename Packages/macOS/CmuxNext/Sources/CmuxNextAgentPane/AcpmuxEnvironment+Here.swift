public import Foundation

extension AcpmuxEnvironment {
    /// Reads machine-wide presence and peer acknowledgements without starting a daemon.
    /// An older daemon can answer presence without `sync`; transport and malformed-reply
    /// errors throw rather than masquerading as an empty or synced machine.
    public nonisolated func here(scope: String? = nil, deadline: Duration = .seconds(3)) async throws -> AcpmuxHere {
        var params: [String: any Sendable] = ["includeSync": true]
        if let scope { params["scope"] = scope }
        let result = try await AcpmuxStatusClient.call(
            socketPath: socketPath, method: "_acpmux/here", params: params, deadline: deadline)
        return try AcpmuxHere(result: result)
    }
}
