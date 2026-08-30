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
    /// The irx lifecycle remains visible even when its route is torn down.
    let irxActivationState: IrxHostActivationState
    let irxBrokerFailure: IrxBrokerFailure?

    var payload: [String: Any] {
        let now = Date()
        return [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "configured_port": configuredPort,
            "uses_ephemeral_fallback": usesEphemeralFallback,
            "routes": routes.mobileHostJSONObjects(for: .authenticated, at: now),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull(),
            "iroh_activation_state": irxActivationState.rawValue,
            "iroh_requires_reauthentication": irxActivationState
                == .reauthenticationRequired,
            "iroh_broker_operation": irxBrokerFailure?.operation.rawValue ?? NSNull(),
            "iroh_broker_error_code": irxBrokerFailure?.errorCode ?? NSNull()
        ]
    }
}
