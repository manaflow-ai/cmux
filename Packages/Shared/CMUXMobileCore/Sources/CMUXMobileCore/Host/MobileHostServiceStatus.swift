public import Foundation

/// A snapshot of the mobile host listener's reachability and binding state.
///
/// A pure value composed only of `Sendable` fields (`routes` is `[CmxAttachRoute]`,
/// already in this package), so it carries no actor or `MobileHostService` state and
/// can cross isolation boundaries freely. It is the single shape the host's status
/// surfaces project from: the settings pairing bridge reads its stored fields, and
/// ``payload`` builds the DEBUG/non-boundary `[String: Any]` reply body.
public struct MobileHostServiceStatus: Sendable {
    public let isRunning: Bool
    public let port: Int?
    /// The preferred port from settings the listener tried to bind.
    public let configuredPort: Int
    /// True when the listener is running on an OS-assigned ephemeral port
    /// because the configured port could not be bound.
    public let usesEphemeralFallback: Bool
    public let routes: [CmxAttachRoute]
    public let activeConnectionCount: Int
    public let lastErrorDescription: String?

    public init(
        isRunning: Bool,
        port: Int?,
        configuredPort: Int,
        usesEphemeralFallback: Bool,
        routes: [CmxAttachRoute],
        activeConnectionCount: Int,
        lastErrorDescription: String?
    ) {
        self.isRunning = isRunning
        self.port = port
        self.configuredPort = configuredPort
        self.usesEphemeralFallback = usesEphemeralFallback
        self.routes = routes
        self.activeConnectionCount = activeConnectionCount
        self.lastErrorDescription = lastErrorDescription
    }

    /// The Foundation `[String: Any]` reply body for the host status. Non-`Sendable`
    /// by construction (it carries `NSNull`), so it stays a computed accessor used at
    /// DEBUG/non-boundary call sites rather than a stored field.
    ///
    /// `routes.map(\.mobileHostJSONObject)` resolves to the in-package
    /// ``CmxAttachRoute/mobileHostJSONObject`` accessor, so this type and its wire
    /// projection live entirely within `CMUXMobileCore`.
    public var payload: [String: Any] {
        [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "configured_port": configuredPort,
            "uses_ephemeral_fallback": usesEphemeralFallback,
            "routes": routes.map(\.mobileHostJSONObject),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull()
        ]
    }
}
