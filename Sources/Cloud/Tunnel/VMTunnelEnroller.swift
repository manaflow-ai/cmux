import Foundation

/// ``CloudTunnelEnrolling`` over ``VMTunnelManager``: keypair and device
/// identity on this Mac, `/api/vm/tunnel` for the peer half, the completed
/// wg-quick config as the result. Idempotent per device, so it runs on every
/// tunnel start and picks up a rotated peer or endpoint for free.
struct VMTunnelEnroller: CloudTunnelEnrolling {
    let manager: VMTunnelManager

    init(manager: VMTunnelManager = VMTunnelManager()) {
        self.manager = manager
    }

    func enroll() async throws -> CloudTunnelEnrollment {
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
