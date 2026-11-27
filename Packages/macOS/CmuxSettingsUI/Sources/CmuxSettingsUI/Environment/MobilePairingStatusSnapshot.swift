import Foundation

/// A point-in-time view of the Mac-side iOS pairing host, shown in the Mobile
/// settings section.
///
/// Reports the actual IROH UDP port and local addresses. A saved preference
/// takes effect at the next pairing start; pending changes are distinguished
/// from an unavailable port that required an automatic fallback.
///
/// The host supplies the snapshot through
/// ``SettingsHostActions/mobilePairingStatus()`` and pushes updates through
/// ``SettingsHostActions/mobilePairingStatusUpdates()``. The settings package
/// stays Foundation-only; the host maps its own runtime types into this value.
public struct MobilePairingStatusSnapshot: Sendable, Equatable {
    /// Whether the pairing listener is currently bound and accepting iOS
    /// connections.
    public let isRunning: Bool

    /// The preferred port from settings the listener tried to bind.
    public let configuredPort: Int

    /// The port the listener actually bound, or `nil` when it is not running.
    public let boundPort: Int?

    /// True when the listener is running on a different port than
    /// ``configuredPort`` because the configured port could not be bound.
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
    ///   - configuredPort: The preferred port from settings.
    ///   - boundPort: The port actually bound, or `nil` when not running.
    ///   - usesEphemeralFallback: True when the bound port differs from the
    ///     configured port because the configured port was unavailable.
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
