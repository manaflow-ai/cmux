import Foundation

/// ``CloudTunnelEnrolling`` over ``VMTunnelManager``: keypair and device
/// identity on this Mac, `/api/vm/tunnel` for the peer half, and the completed
/// WireGuard config as the result. A saved config is reused, so normal browser
/// opens do not call the control plane or Freestyle.
struct VMTunnelEnroller: CloudTunnelEnrolling {
    let manager: VMTunnelManager

    init(manager: VMTunnelManager = VMTunnelManager()) {
        self.manager = manager
    }

    func enroll() async throws -> CloudTunnelEnrollment {
        if let config = manager.writtenConfig() {
            return CloudTunnelEnrollment(
                wgQuickConfig: config,
                serverAddress: "cmux Cloud"
            )
        }
        let client: VMClient? = await MainActor.run { VMClient.shared }
        guard let client else { throw CloudTunnelError.notSignedIn }
        let state = try await manager.enroll(client: client)
        return CloudTunnelEnrollment(
            wgQuickConfig: state.completedConfig,
            serverAddress: Self.serverAddress(for: state.endpoint)
        )
    }

    /// `host:port` for System Settings' server address column.
    static func serverAddress(for endpoint: VMTunnelEndpoint) -> String {
        guard let host = endpoint.endpointHost, !host.isEmpty else { return "cmux Cloud" }
        return "\(host):\(endpoint.endpointPort)"
    }
}
