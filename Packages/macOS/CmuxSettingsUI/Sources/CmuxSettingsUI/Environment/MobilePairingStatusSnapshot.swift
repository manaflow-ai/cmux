import Foundation

/// A point-in-time view of the Mac-side iOS pairing host, shown in the Mobile
/// settings section.
///
/// Reports the legacy Tailscale TCP port and reachable addresses. Iroh owns a
/// separate UDP endpoint and is not represented by the configured TCP port.
///
/// The host supplies the snapshot through
/// ``SettingsHostActions/mobilePairingStatus()`` and pushes updates through
/// ``SettingsHostActions/mobilePairingStatusUpdates()``. The settings package
/// stays Foundation-only; the host maps its own runtime types into this value.
public struct MobilePairingStatusSnapshot: Sendable, Equatable {
    /// Whether the pairing listener is currently bound and accepting iOS
    /// connections.
    public let isRunning: Bool

    /// The configured legacy Tailscale TCP port.
    public let configuredPort: Int

    /// The Tailscale TCP port actually bound, or `nil` when it is not running.
    public let boundPort: Int?

    /// Retained for compatibility with older settings clients. Tailscale
    /// binding failures do not silently fall back to another port.
    public let usesEphemeralFallback: Bool

    /// A saved port will take effect at the next pairing start.
    public let pendingPortChange: Bool

    /// Number of iOS devices currently connected.
    public let activeConnectionCount: Int

    /// The addresses the iOS app can use to reach this Mac.
    public let routes: [MobilePairingRoute]

    /// Creates a pairing-status snapshot.
    ///
    /// - Parameters:
    ///   - isRunning: Whether the listener is bound.
    ///   - configuredPort: The configured Tailscale TCP port.
    ///   - boundPort: The Tailscale TCP port actually bound, or `nil` when not running.
    ///   - usesEphemeralFallback: Compatibility field; always false for the TCP listener.
    ///   - activeConnectionCount: Number of connected iOS devices.
    ///   - routes: Addresses the iOS app can use to reach this Mac.
    public init(
        isRunning: Bool,
        configuredPort: Int,
        boundPort: Int?,
        usesEphemeralFallback: Bool,
        activeConnectionCount: Int,
        routes: [MobilePairingRoute],
        pendingPortChange: Bool = false
    ) {
        self.isRunning = isRunning
        self.configuredPort = configuredPort
        self.boundPort = boundPort
        self.usesEphemeralFallback = usesEphemeralFallback
        self.activeConnectionCount = activeConnectionCount
        self.routes = routes
        self.pendingPortChange = pendingPortChange
    }
}
