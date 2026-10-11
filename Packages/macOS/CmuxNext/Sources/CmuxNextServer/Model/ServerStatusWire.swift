public import Foundation

/// The proposed JSON of `server.status` / `cmux server status --json`, and
/// its mapping into `ServerSnapshot`. Lenient where a newer server may say
/// more: unknown roles and devices are dropped, unknown states read as
/// unavailable or stopped, unknown check ids are kept.
public nonisolated struct ServerStatusWire: Decodable, Sendable {
    struct Store: Decodable, Sendable {
        var version: String
        var channel: String
        var pinned: Bool?
    }

    struct AppServer: Decodable, Sendable {
        var app: String
        var name: String
        var state: String
        var leaseEpoch: UInt64
        var holdsLease: Bool
        var durability: String
        var lastRestartMs: Int64?
    }

    struct Database: Decodable, Sendable {
        var app: String
        var sizeBytes: Int64
        var quotaBytes: Int64
    }

    struct Browser: Decodable, Sendable {
        var state: String
        var pages: Int?
    }

    struct Pairing: Decodable, Sendable {
        var state: String
        var code: String?
        var expiresAtMs: Int64?
        var words: [String]?
        var fingerprint: String?
        var team: String?
        var owner: String?
        var host: String?
    }

    struct Device: Decodable, Sendable {
        var id: String
        var name: String
        var kind: String
        var lastSeenMs: Int64?
    }

    struct Fix: Decodable, Sendable {
        var title: String
        var needsAdmin: Bool?
        var opensSettings: Bool?
    }

    struct Alert: Decodable, Sendable {
        var check: String
        var severity: String
        var title: String
        var body: String
        var fix: Fix?
        var raisedAtMs: Int64
        var resolvedAtMs: Int64?
    }

    var hostName: String
    var platform: String
    var enabled: Bool
    var mode: String
    var roles: [String: String]
    var terminals: Int
    var appServers: [AppServer]?
    var databases: [Database]?
    var browser: Browser?
    var automations: Int?
    var pairing: Pairing
    var devices: [Device]?
    var checks: [String]
    var alerts: [Alert]
    var store: Store

    /// Decodes a `server.status` reply (snake_case keys).
    public static func decode(_ data: Data) throws -> ServerSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ServerStatusWire.self, from: data).snapshot()
    }

    public func snapshot() -> ServerSnapshot {
        ServerSnapshot(
            hostName: hostName,
            platform: ServerPlatform(rawValue: platform) ?? .linux,
            enabled: enabled,
            mode: ServerInstallMode(rawValue: mode) ?? .user,
            roles: ServerRole.allCases.compactMap { role in
                roles[role.rawValue].map { ServerRoleStatus(role, ServerRoleState(rawValue: $0) ?? .unavailable) }
            },
            terminals: terminals,
            appServers: (appServers ?? []).map { app in
                ServerAppServer(
                    appID: app.app, name: app.name, state: AppServerState(rawValue: app.state) ?? .stopped,
                    leaseEpoch: app.leaseEpoch, holdsLease: app.holdsLease,
                    durability: AppDataDurability(rawValue: app.durability) ?? .bounded,
                    lastRestart: app.lastRestartMs.map(Self.date))
            },
            databases: (databases ?? []).map { ServerDatabase(app: $0.app, sizeBytes: $0.sizeBytes, quotaBytes: $0.quotaBytes) },
            browser: browserState,
            automations: automations ?? 0,
            pairing: pairingState,
            devices: (devices ?? []).compactMap { device in
                ServerDevice.Kind(rawValue: device.kind).map {
                    ServerDevice(id: device.id, name: device.name, kind: $0, lastSeen: device.lastSeenMs.map(Self.date))
                }
            },
            checks: checks.map(HealthCheckID.init(rawValue:)),
            alerts: alerts.map { alert in
                HealthAlert(
                    check: HealthCheckID(alert.check), severity: HealthSeverity(rawValue: alert.severity) ?? .warning,
                    title: alert.title, body: alert.body,
                    fix: alert.fix.map { HealthFix(title: $0.title, needsAdmin: $0.needsAdmin ?? false, opensSettings: $0.opensSettings ?? false) },
                    raisedAt: Self.date(alert.raisedAtMs), resolvedAt: alert.resolvedAtMs.map(Self.date))
            },
            store: ServerStoreInfo(version: store.version, channel: store.channel, pinned: store.pinned ?? false))
    }

    private var browserState: ServerBrowserState {
        switch browser?.state {
        case "idle": .idle
        case "running": .running(pages: browser?.pages ?? 0)
        case "unavailable": .unavailable
        default: .off
        }
    }

    private var pairingState: ServerPairingState {
        switch pairing.state {
        case "paired":
            return .paired(ServerPairing(team: pairing.team ?? "", owner: pairing.owner ?? "", hostID: pairing.host ?? ""))
        case "pairing":
            return .pairing
        default:
            guard let code = pairing.code, let expires = pairing.expiresAtMs else { return .unpaired(nil) }
            return .unpaired(PairingOffer(code: PairingCode.normalize(code), expiresAt: Self.date(expires),
                                          words: pairing.words ?? [], fingerprint: pairing.fingerprint ?? ""))
        }
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
