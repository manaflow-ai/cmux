public import Foundation

/// A projection of `server.status` (plans/cmux-next/server.md section 13).
/// The `server` role on that machine owns every fact; the app only renders
/// it, so this is a plain value the source replaces as a whole.
public nonisolated struct ServerSnapshot: Sendable, Equatable {
    public var hostName: String
    public var platform: ServerPlatform
    public var enabled: Bool
    public var mode: ServerInstallMode
    public var roles: [ServerRoleStatus]
    public var terminals: Int
    public var appServers: [ServerAppServer]
    public var databases: [ServerDatabase]
    public var browser: ServerBrowserState
    public var automations: Int
    public var pairing: ServerPairingState
    public var devices: [ServerDevice]
    /// The checks the health role runs on this platform and role set.
    public var checks: [HealthCheckID]
    /// Open and recently resolved alerts, in any order.
    public var alerts: [HealthAlert]
    public var store: ServerStoreInfo

    public init(
        hostName: String, platform: ServerPlatform, enabled: Bool, mode: ServerInstallMode,
        roles: [ServerRoleStatus], terminals: Int, appServers: [ServerAppServer], databases: [ServerDatabase],
        browser: ServerBrowserState, automations: Int, pairing: ServerPairingState, devices: [ServerDevice],
        checks: [HealthCheckID], alerts: [HealthAlert], store: ServerStoreInfo
    ) {
        self.hostName = hostName
        self.platform = platform
        self.enabled = enabled
        self.mode = mode
        self.roles = roles
        self.terminals = terminals
        self.appServers = appServers
        self.databases = databases
        self.browser = browser
        self.automations = automations
        self.pairing = pairing
        self.devices = devices
        self.checks = checks
        self.alerts = alerts
        self.store = store
    }

    public func state(of role: ServerRole) -> ServerRoleState {
        roles.first { $0.role == role }?.state ?? .off
    }

    /// Bytes used by every app database.
    public var databaseBytes: Int64 { databases.reduce(0) { $0 + $1.sizeBytes } }
}

public nonisolated enum ServerPlatform: String, Sendable, Equatable, Codable {
    case macOS = "macos"
    case linux
    case windows
}

/// `user`: no root, runs as the installing user. `system`: root once, a
/// dedicated service user (server.md section 2).
public nonisolated enum ServerInstallMode: String, Sendable, Equatable, Codable {
    case user
    case system
}
