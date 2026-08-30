import CMUXMobileCore
import CmuxIrxTransport
import Foundation

/// A credential-free point-in-time snapshot of the Mac mobile host.
struct MobileHostServiceStatus {
    let isRunning: Bool
    let port: Int?
    let configuredPort: Int
    let usesEphemeralFallback: Bool
    let routes: [CmxAttachRoute]
    let activeConnectionCount: Int
    let lastErrorDescription: String?
    /// Lifecycle state selected from the owning runtime when this snapshot was captured.
    let effectiveIrohActivationState: IrxHostActivationState

    var payload: [String: Any] {
        let now = Date()
        let irohState = effectiveIrohActivationState
        return [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "configured_port": configuredPort,
            "uses_ephemeral_fallback": usesEphemeralFallback,
            "routes": routes.mobileHostJSONObjects(for: .authenticated, at: now),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull(),
            "iroh_activation_state": irohState.rawValue,
            "iroh_requires_reauthentication": irohState
                == .reauthenticationRequired
        ]
    }
}
