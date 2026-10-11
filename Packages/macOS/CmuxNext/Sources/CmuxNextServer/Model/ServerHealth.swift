public import Foundation

/// A health check id (server.md section 9.3). Open-ended: a newer server
/// may report checks this app does not know; they render by their title.
public nonisolated struct HealthCheckID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let onBattery = HealthCheckID("power.onBattery")
    public static let offline = HealthCheckID("network.offline")
    public static let diskLow = HealthCheckID("disk.low")
    public static let lockPending = HealthCheckID("lock.pending")
    public static let sleepEnabled = HealthCheckID("sleep.enabled")
    public static let noAutoRestart = HealthCheckID("restart.noAutoRestart")
    public static let fileVaultWait = HealthCheckID("restart.fileVaultWait")
    public static let notLoggedIn = HealthCheckID("restart.notLoggedIn")
    public static let lingerOff = HealthCheckID("linger.off")
    public static let encryptionOff = HealthCheckID("encryption.off")
    public static let postgresQuota = HealthCheckID("postgres.quota")
    public static let backupStale = HealthCheckID("backup.stale")

    /// Every check of section 9.3, in table order.
    public static let known: [HealthCheckID] = [
        .onBattery, .offline, .diskLow, .lockPending, .sleepEnabled, .noAutoRestart,
        .fileVaultWait, .notLoggedIn, .lingerOff, .encryptionOff, .postgresQuota, .backupStale,
    ]
}

public nonisolated enum HealthSeverity: String, Sendable, Equatable, Codable, Comparable {
    case info, warning, critical

    /// Higher is more urgent.
    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (a: HealthSeverity, b: HealthSeverity) -> Bool { a.rank < b.rank }
}

/// A one-click fix (section 9.4). `needsAdmin`: the privileged helper asks
/// for an administrator once. `opensSettings`: the fix opens a settings
/// pane instead of changing anything.
public nonisolated struct HealthFix: Sendable, Equatable {
    public var title: String
    public var needsAdmin: Bool
    public var opensSettings: Bool

    public init(title: String, needsAdmin: Bool = false, opensSettings: Bool = false) {
        self.title = title
        self.needsAdmin = needsAdmin
        self.opensSettings = opensSettings
    }
}
