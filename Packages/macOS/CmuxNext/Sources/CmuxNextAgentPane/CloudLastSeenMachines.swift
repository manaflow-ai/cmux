public import CmuxNextCloud
public import Foundation

/// The machine list each team last answered, kept on this Mac so a cold start with the control
/// plane slow or down shows the machines it knew at once, marked last seen, instead of none
/// (cmuxterm-hq docs/reading/2026-11-22-tailscale-netmap-caching.md). The file's format, whose
/// list may be shown and for how long are Rust's (cmux-cloud-machine `last_seen.rs`; the file
/// itself, cmux-layout-reducer-ffi `cloud_last_seen.rs`); this only hands over rows and the account.
@MainActor
public final class CloudLastSeenMachines {
    /// Whether the picker shows a kept list before the first fresh one lands. Off until Leo picks
    /// how stale rows look (a taste call); the probe and a person trying it turn it on with
    /// `defaults write <bundle id> cloud.machines.showLastSeen -bool true`. The list is kept either way.
    public static let showKey = "cloud.machines.showLastSeen"

    private let dir: String?
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    /// The last write: each write waits for the one before, so the newest list is the one on disk.
    /// Whether an unchanged list is written again is Rust's (`last_seen::unchanged`, read off the file a write that succeeded left).
    private var saving: Task<Void, Never>?
    /// The fresh read a kept list's answer started (true: it landed); one at a time, cancelled at sign-out.
    private var refreshing: Task<Bool, Never>?
    /// Failed refreshes in a row and when the last one started: Rust spaces background refreshes by them
    /// (`last_seen::refresh_due`), so a control plane that stays down is not asked every few seconds.
    private var failures: UInt32 = 0
    private var lastAttempt: Date?

    public init(stateDirectory: URL?, defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = { .now }) {
        dir = stateDirectory?.path
        self.defaults = defaults
        self.now = now
    }

    public var shows: Bool { defaults.bool(forKey: Self.showKey) }

    /// The kept list for `account` (`[user id, team id]`) when it may be shown now; nil otherwise.
    public func shown(for account: [String?]) -> (at: Date, machines: [AgentPaneCloudMachines.Machine])? {
        guard shows, let dir, let user = account.first ?? nil, !user.isEmpty else { return nil }
        let request = Load(dir: dir, user: user, team: account.count > 1 ? account[1] : nil, now: Self.ms(now()))
        guard let snapshot = CloudMachineRules().call("cloud_machine_last_seen_load", request, as: LoadReply.self)?.snapshot else { return nil }
        return (Date(timeIntervalSince1970: Double(snapshot.at) / 1000), snapshot.machines.map(Self.machine))
    }

    /// A cold start's answer to the picker: the kept list for `account` marked last seen (never
    /// complete); nil when no kept list may be shown. `refresh` is the fresh read (true: it landed).
    /// A plain read (`fresh` false) answers at once and starts `refresh` behind it when Rust's backoff
    /// says one is due. A fresh read (`fresh`: Retry, a pick of a kept row) waits for `refresh`, the
    /// one in flight or a new one at once, and answers nil when it landed (the caller then answers the
    /// fresh list), the kept list again when it did not.
    public func inventory(for account: [String?], team: AgentPaneCloudMachines.Team?, teams: [AgentPaneCloudMachines.Team], fresh: Bool = false,
                          refresh: @escaping @MainActor () async -> Bool) async -> AgentPaneCloudMachines.Inventory? {
        guard let kept = shown(for: account) else { return nil }
        if fresh {
            if await refreshNow(refresh) { return nil }
        } else if refreshing == nil, refreshDue {
            _ = start(refresh)
        }
        return .init(signedIn: true, loaded: true, machines: kept.machines, account: account, complete: false,
                     team: team, teams: teams, lastSeenAt: kept.at)
    }

    /// Whether a background refresh may start now (`cloud_machine_last_seen_refresh_due`); when Rust does not answer, it may.
    private var refreshDue: Bool {
        let since = lastAttempt.map { Self.ms(now()) - Self.ms($0) }
        return CloudMachineRules().call("cloud_machine_last_seen_refresh_due", RefreshDue(failures: failures, sinceLastMs: since), as: RefreshDueReply.self)?.due ?? true
    }

    /// The refresh in flight, else a new one started now; true when it landed.
    private func refreshNow(_ refresh: @escaping @MainActor () async -> Bool) async -> Bool {
        await (refreshing ?? start(refresh)).value
    }

    private func start(_ refresh: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        lastAttempt = now()
        let task = Task { [weak self] in
            let landed = await refresh()
            if let self, !Task.isCancelled {
                self.failures = landed ? 0 : self.failures &+ 1
                self.refreshing = nil
            }
            return landed
        }
        refreshing = task
        return task
    }

    /// Keeps `machines`, a list the server answered for `account` just now. Off the main thread.
    public func keep(_ machines: [AgentPaneCloudMachines.Machine], for account: [String?]) {
        guard let dir, let user = account.first ?? nil, !user.isEmpty else { return }
        failures = 0
        let request = Save(dir: dir, user: user, team: account.count > 1 ? account[1] : nil, at: Self.ms(now()), machines: machines.map(Self.row))
        let previous = saving
        saving = Task.detached(priority: .utility) {
            await previous?.value
            _ = CloudMachineRules().call("cloud_machine_last_seen_save", request, as: SaveReply.self)
        }
    }

    /// Removes every kept list and any write's leftover temporary file (sign-out), after any write still on its way.
    public func forget() {
        refreshing?.cancel()
        refreshing = nil
        failures = 0
        lastAttempt = nil
        guard let dir else { return }
        let previous = saving
        saving = Task.detached(priority: .utility) {
            await previous?.value
            _ = CloudMachineRules().call("cloud_machine_last_seen_forget", ["dir": dir], as: [String: Int].self)
        }
    }

    /// Waits for the refresh in flight and every write and removal asked so far (tests).
    public func settled() async {
        _ = await refreshing?.value
        await saving?.value
    }

    private nonisolated static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private nonisolated struct Row: Codable, Sendable {
        var id: String, name: String, stage: String
        var evictAt: Int64?
        var size: Size?
    }

    private static func row(_ machine: AgentPaneCloudMachines.Machine) -> Row {
        Row(id: machine.id, name: machine.name, stage: machine.stage, evictAt: machine.evictAt.map(ms),
            size: machine.size.map { Size(cpu: $0.cpu, memoryMb: $0.memoryMb, diskMb: $0.diskMb) })
    }

    private static func machine(_ row: Row) -> AgentPaneCloudMachines.Machine {
        AgentPaneCloudMachines.Machine(id: row.id, name: row.name, stage: row.stage, evictAt: row.evictAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                       size: row.size.map { .init(cpu: $0.cpu, memoryMb: $0.memoryMb, diskMb: $0.diskMb) })
    }

    private nonisolated struct Size: Codable, Sendable { var cpu: Int?, memoryMb: Int?, diskMb: Int? }
    private nonisolated struct Save: Encodable, Sendable { var dir: String, user: String, team: String?, at: Int64, machines: [Row] }
    private nonisolated struct SaveReply: Decodable { var ok: Bool, written: Bool? }
    private nonisolated struct Load: Encodable { var dir: String, user: String, team: String?, now: Int64 }
    private nonisolated struct LoadReply: Decodable { var snapshot: Snapshot? }
    private nonisolated struct Snapshot: Decodable { var at: Int64, machines: [Row] }
    private nonisolated struct RefreshDue: Encodable { var failures: UInt32, sinceLastMs: Int64? }
    private nonisolated struct RefreshDueReply: Decodable { var due: Bool }
}
