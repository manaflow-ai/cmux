/// A pure-value snapshot of the mobile pairing host's observable state: whether
/// the listener is bound, the port it bound (and the configured port it tried),
/// whether it fell back to an OS-assigned ephemeral port, the reachable attach
/// routes, the live connection count, and the last bind error.
///
/// Identity-free and `Sendable` so it can ride `AsyncStream`/`CheckedContinuation`
/// across the main actor without copying app state. The app-side
/// `payload` extension renders it for the `mobile.host.status` wire reply, since
/// that rendering depends on `CmxAttachRoute.mobileHostJSONObject`, an app
/// extension.
public struct MobileHostServiceStatus: Sendable {
    /// True while the listener is bound and accepting connections.
    public let isRunning: Bool
    /// The port the listener actually bound, or `nil` when not running.
    public let port: Int?
    /// The preferred port from settings the listener tried to bind.
    public let configuredPort: Int
    /// True when the listener is running on an OS-assigned ephemeral port
    /// because the configured port could not be bound.
    public let usesEphemeralFallback: Bool
    /// The reachable attach routes peers can dial.
    public let routes: [CmxAttachRoute]
    /// The number of live connections to the listener.
    public let activeConnectionCount: Int
    /// A human-readable description of the last bind error, or `nil`.
    public let lastErrorDescription: String?

    /// Memberwise initializer mirroring the field order of the relocated value.
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
}
