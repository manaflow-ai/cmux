public import CmuxNextDaemon
public import Foundation

/// Shared forwarding closures for Cloud repository frames. The app supplies only the endpoint
/// details; connection lifetime and error propagation stay with the package that owns the wire.
extension AgentSessionAttachClient {
    public typealias CloudRepositoryEndpoint = @Sendable () async throws -> DaemonEndpoint
    public typealias CloudRepositoryReconnect = @Sendable () async -> Bool

    public nonisolated static func forwardingCloudRepository(
        surface: UInt64,
        reconnect: CloudRepositoryReconnect?,
        endpoint: @escaping CloudRepositoryEndpoint,
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

    public nonisolated static func forwardingCloudRepository(
        surface: UInt64,
        reconnect: CloudRepositoryReconnect?,
        endpoint: @escaping CloudRepositoryEndpoint
    ) -> @Sendable (String, [String: any Sendable], Duration?) async throws -> Data {
        { method, params, timeout in
            try await forwardingCloudRepository(surface: surface, reconnect: reconnect, endpoint: endpoint,
                              method: method, params: params, timeout: timeout)
        }
    }

    public nonisolated static func forwardingStartedCloudRepository(
        reconnect: CloudRepositoryReconnect?,
        endpoint: @escaping CloudRepositoryEndpoint
    ) -> @Sendable (UInt64, String, [String: any Sendable], Duration?) async throws -> Data {
        { surface, method, params, timeout in
            try await forwardingCloudRepository(surface: surface, reconnect: reconnect, endpoint: endpoint,
                              method: method, params: params, timeout: timeout)
        }
    }
}
