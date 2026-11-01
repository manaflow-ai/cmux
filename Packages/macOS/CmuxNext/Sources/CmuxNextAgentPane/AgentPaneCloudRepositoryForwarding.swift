public import CmuxNextDaemon
public import Foundation

/// Shared forwarding closures for Cloud repository frames. The app supplies only the endpoint
/// details; connection lifetime and error propagation stay with the package that owns the wire.
public nonisolated enum AgentPaneCloudRepositoryForwarding {
    public typealias Endpoint = @Sendable () async throws -> DaemonEndpoint
    public typealias Reconnect = @Sendable () async -> Bool

    public static func request(
        surface: UInt64,
        reconnect: Reconnect?,
        endpoint: @escaping Endpoint,
        method: String,
        params: [String: any Sendable],
        timeout: Duration?
    ) async throws -> Data {
        let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
        let result: Result<Data, any Error>
        do {
            result = .success(try await client.cloudRepository(method: method, params: params, timeout: timeout))
        } catch {
            result = .failure(error)
        }
        await client.close()
        return try result.get()
    }

    public static func request(
        surface: UInt64,
        reconnect: Reconnect?,
        endpoint: @escaping Endpoint
    ) -> @Sendable (String, [String: any Sendable], Duration?) async throws -> Data {
        { method, params, timeout in
            try await request(surface: surface, reconnect: reconnect, endpoint: endpoint,
                              method: method, params: params, timeout: timeout)
        }
    }

    public static func startRequest(
        reconnect: Reconnect?,
        endpoint: @escaping Endpoint
    ) -> @Sendable (UInt64, String, [String: any Sendable], Duration?) async throws -> Data {
        { surface, method, params, timeout in
            try await request(surface: surface, reconnect: reconnect, endpoint: endpoint,
                              method: method, params: params, timeout: timeout)
        }
    }
}
