public import Foundation

/// Canned servers for the demo and tests (mock data, English only).
public nonisolated enum MockServerScenario: String, Sendable, CaseIterable {
    /// A paired Mac mini, every role up, one info alert.
    case healthyMac
    /// A MacBook on battery with low disk and the screen about to lock.
    case batteryLowDisk
    /// A fresh Mac server showing its pairing code.
    case unpaired
    /// A paired Linux box without a display (user mode, no linger).
    case linuxHeadless

    /// 2026-10-02 14:20 PDT, so screenshots and tests are stable.
    public static let referenceDate = Date(timeIntervalSince1970: 1_790_976_000)
    public static let offerCode = "7KQ4M2XD"
    public static let offerWords = ["copper", "lantern", "meadow", "violet"]
    public static let offerFingerprint = "Q4M2XD7KHJ9P3RTV"

    public static func offer(now: Date) -> PairingOffer {
        PairingOffer(code: offerCode, expiresAt: now.addingTimeInterval(600), words: offerWords, fingerprint: offerFingerprint)
    }

    /// The pending server the approver finds with `offerCode`.
    public static let candidate = PairingCandidate(
        code: offerCode, name: "build-01", os: "Ubuntu 24.04 arm64", version: "cmux 0.42.1", region: "DE",
        words: offerWords,
        teams: [ServerTeam(id: "team_personal", name: "Personal"), ServerTeam(id: "team_manaflow", name: "Manaflow")])

    public func snapshot(now: Date) -> ServerSnapshot {
        switch self {
        case .healthyMac: Self.healthy(now)
        case .batteryLowDisk: Self.onBattery(now)
        case .unpaired: Self.fresh(now)
        case .linuxHeadless: Self.linux(now)
        }
    }

    private static let macChecks: [HealthCheckID] = [
        .onBattery, .offline, .diskLow, .lockPending, .sleepEnabled, .noAutoRestart,
        .fileVaultWait, .encryptionOff, .postgresQuota, .backupStale,
    ]
    private static let linuxChecks: [HealthCheckID] = [.offline, .diskLow, .lingerOff, .encryptionOff, .postgresQuota, .backupStale]
    private static let gib: Int64 = 1 << 30
    private static let mib: Int64 = 1 << 20

    private static func roles(_ off: Set<ServerRole> = [], failed: Set<ServerRole> = [], unavailable: Set<ServerRole> = []) -> [ServerRoleStatus] {
        ServerRole.allCases.map { role in
            if failed.contains(role) { return ServerRoleStatus(role, .failed) }
            if unavailable.contains(role) { return ServerRoleStatus(role, .unavailable) }
            return ServerRoleStatus(role, off.contains(role) ? .off : .on)
        }
    }

    private static func apps(_ now: Date) -> [ServerAppServer] {
        [
            ServerAppServer(appID: "dev.cmux.tasks", name: "Tasks", state: .running, leaseEpoch: 7, holdsLease: true,
                            durability: .zeroLoss, lastRestart: now.addingTimeInterval(-86_400 * 3)),
            ServerAppServer(appID: "dev.cmux.notes", name: "Notes", state: .running, leaseEpoch: 2, holdsLease: true,
                            durability: .bounded, lastRestart: now.addingTimeInterval(-7_200)),
            ServerAppServer(appID: "dev.cmux.hooks", name: "Webhooks", state: .stopped, leaseEpoch: 4, holdsLease: false,
                            durability: .bounded, lastRestart: nil),
        ]
    }

    private static func devices(_ now: Date) -> [ServerDevice] {
        [
            ServerDevice(id: "dev_mbp", name: "MacBook Pro", kind: .mac, lastSeen: now.addingTimeInterval(-120)),
            ServerDevice(id: "dev_phone", name: "iPhone", kind: .phone, lastSeen: now.addingTimeInterval(-3_600)),
            ServerDevice(id: "dev_web", name: "cmux.com", kind: .web, lastSeen: now.addingTimeInterval(-86_400 * 2)),
        ]
    }

    private static func healthy(_ now: Date) -> ServerSnapshot {
        ServerSnapshot(
            hostName: "Mac mini", platform: .macOS, enabled: true, mode: .user,
            roles: roles([.automations]), terminals: 14, appServers: apps(now),
            databases: [
                ServerDatabase(app: "Tasks", sizeBytes: 412 * mib, quotaBytes: 5 * gib),
                ServerDatabase(app: "Notes", sizeBytes: 38 * mib, quotaBytes: 5 * gib),
            ],
            browser: .running(pages: 3), automations: 4,
            pairing: .paired(ServerPairing(team: "Manaflow", owner: "Lawrence", hostID: "host_7f3k2q")),
            devices: devices(now), checks: macChecks,
            alerts: [
                HealthAlert(check: .sleepEnabled, severity: .info, title: "Sleep on power adapter is on",
                            body: "A scheduled sleep can still stop the server.",
                            fix: HealthFix(title: "Turn Off Sleep", needsAdmin: true), raisedAt: now.addingTimeInterval(-7_200)),
                HealthAlert(check: .onBattery, severity: .warning, title: "On battery",
                            body: "Power came back after 4 minutes.", raisedAt: now.addingTimeInterval(-86_000),
                            resolvedAt: now.addingTimeInterval(-85_760)),
            ],
            store: ServerStoreInfo(version: "0.42.1", channel: "nightly", pinned: false))
    }

    private static func onBattery(_ now: Date) -> ServerSnapshot {
        ServerSnapshot(
            hostName: "MacBook Air", platform: .macOS, enabled: true, mode: .user,
            roles: roles([.automations, .browser]), terminals: 6, appServers: Array(apps(now).prefix(2)),
            databases: [ServerDatabase(app: "Tasks", sizeBytes: 1_300 * mib, quotaBytes: 5 * gib)],
            browser: .off, automations: 0,
            pairing: .paired(ServerPairing(team: "Personal", owner: "Lawrence", hostID: "host_2m9w4c")),
            devices: Array(devices(now).prefix(2)), checks: macChecks,
            alerts: [
                HealthAlert(check: .onBattery, severity: .critical, title: "On battery, 18%",
                            body: "Plug in power. The server stops when the battery runs out.",
                            raisedAt: now.addingTimeInterval(-900)),
                HealthAlert(check: .diskLow, severity: .warning, title: "8.2 GB free",
                            body: "Below 10 GB. Builds and databases may fail.",
                            fix: HealthFix(title: "Open Storage", opensSettings: true), raisedAt: now.addingTimeInterval(-3_600)),
                HealthAlert(check: .lockPending, severity: .warning, title: "Screen locks in 4 minutes",
                            body: "A headful browser is running. The lock stops it.",
                            fix: HealthFix(title: "Keep Display Awake"), raisedAt: now.addingTimeInterval(-60)),
                HealthAlert(check: .offline, severity: .critical, title: "No internet",
                            body: "The link was down for 3 minutes.", raisedAt: now.addingTimeInterval(-14_400),
                            resolvedAt: now.addingTimeInterval(-14_220)),
            ],
            store: ServerStoreInfo(version: "0.42.1", channel: "stable", pinned: false))
    }

    private static func fresh(_ now: Date) -> ServerSnapshot {
        ServerSnapshot(
            hostName: "Studio", platform: .macOS, enabled: true, mode: .user,
            roles: roles([.link, .automations, .postgres, .browser]), terminals: 2, appServers: [],
            databases: [], browser: .off, automations: 0,
            pairing: .unpaired(offer(now: now)), devices: [], checks: macChecks,
            alerts: [
                HealthAlert(check: .noAutoRestart, severity: .info, title: "No restart after power loss",
                            body: "The Mac stays off after a power cut.",
                            fix: HealthFix(title: "Turn On Auto Restart", needsAdmin: true), raisedAt: now.addingTimeInterval(-30)),
            ],
            store: ServerStoreInfo(version: "0.42.1", channel: "stable", pinned: false))
    }

    private static func linux(_ now: Date) -> ServerSnapshot {
        ServerSnapshot(
            hostName: "build-01", platform: .linux, enabled: true, mode: .user,
            roles: roles(unavailable: [.browser]), terminals: 31,
            appServers: [
                ServerAppServer(appID: "dev.cmux.tasks", name: "Tasks", state: .running, leaseEpoch: 3, holdsLease: true,
                                durability: .zeroLoss, lastRestart: now.addingTimeInterval(-86_400)),
                ServerAppServer(appID: "dev.cmux.ci", name: "CI Runner", state: .crashloop, leaseEpoch: 1, holdsLease: true,
                                durability: .bounded, lastRestart: now.addingTimeInterval(-240)),
            ],
            databases: [
                ServerDatabase(app: "Tasks", sizeBytes: 4_300 * mib, quotaBytes: 5 * gib),
                ServerDatabase(app: "CI Runner", sizeBytes: 900 * mib, quotaBytes: 10 * gib),
            ],
            browser: .unavailable, automations: 12,
            pairing: .paired(ServerPairing(team: "Manaflow", owner: "Lawrence", hostID: "host_9q2r8d")),
            devices: devices(now), checks: linuxChecks,
            alerts: [
                HealthAlert(check: .lingerOff, severity: .critical, title: "Stops at logout",
                            body: "User mode without linger. The server stops when you log out.",
                            fix: HealthFix(title: "Enable Linger", needsAdmin: true), raisedAt: now.addingTimeInterval(-600)),
                HealthAlert(check: .postgresQuota, severity: .warning, title: "Tasks at 84% of 5 GB",
                            body: "Writes fail at the quota.", fix: HealthFix(title: "Raise Quota"),
                            raisedAt: now.addingTimeInterval(-5_400)),
                HealthAlert(check: .backupStale, severity: .warning, title: "No backup in 52 hours",
                            body: "The last base backup is from Sep 30.", fix: HealthFix(title: "Back Up Now"),
                            raisedAt: now.addingTimeInterval(-14_400)),
                HealthAlert(check: .encryptionOff, severity: .info, title: "Disk not encrypted",
                            body: "The state volume has no LUKS.", raisedAt: now.addingTimeInterval(-172_800)),
            ],
            store: ServerStoreInfo(version: "0.41.7", channel: "stable", pinned: true))
    }
}
