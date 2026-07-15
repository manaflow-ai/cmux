public import CmuxCore

/// Mints a fresh short-lived daemon WebSocket lease for a durable managed VM.
public protocol ManagedCloudDaemonEndpointRefreshing: Sendable {
    func refreshDaemonEndpoint(
        managedCloudVMID: String
    ) async throws -> WorkspaceRemoteWebSocketDaemonEndpoint
}
