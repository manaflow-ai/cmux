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
    /// Sanitized broker context for a failed activation, when available.
    let irohBrokerFailure: IrxBrokerFailure?

    init(
        isRunning: Bool,
        port: Int?,
        configuredPort: Int,
        usesEphemeralFallback: Bool,
        routes: [CmxAttachRoute],
        activeConnectionCount: Int,
        lastErrorDescription: String?,
        effectiveIrohActivationState: IrxHostActivationState,
        irohBrokerFailure: IrxBrokerFailure? = nil
    ) {
        self.isRunning = isRunning
        self.port = port
        self.configuredPort = configuredPort
        self.usesEphemeralFallback = usesEphemeralFallback
        self.routes = routes
        self.activeConnectionCount = activeConnectionCount
        self.lastErrorDescription = lastErrorDescription
        self.effectiveIrohActivationState = effectiveIrohActivationState
        self.irohBrokerFailure = irohBrokerFailure
    }

    var payload: [String: Any] {
        let now = Date()
        let irohState = effectiveIrohActivationState
        var payload: [String: Any] = [
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
        if let irohBrokerFailure {
            payload["iroh_broker_operation"] = irohBrokerFailure.operation.rawValue
            payload["iroh_broker_error_code"] =
                irohBrokerFailure.diagnosticErrorCode
            if let statusCode = irohBrokerFailure.statusCode {
                payload["iroh_broker_status_code"] = statusCode
            }
        }
        return payload
    }
}
