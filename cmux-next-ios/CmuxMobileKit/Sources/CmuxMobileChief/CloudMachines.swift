import Foundation
import Observation

/// One of the account's Cloud machines as the phone's Cloud Machines page shows it (the Mac's
/// Machines section, Cloud rows): a `cloud.machine.list` item (backend/packages/protocol
/// `CloudMachine`).
public struct CloudMachine: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case provisioning, starting, running, pausing, paused, deleting, failed

        /// A change is under way; the next list settles it.
        public var isTransition: Bool { [.provisioning, .starting, .pausing, .deleting].contains(self) }
    }

    public struct Size: Hashable, Sendable {
        public var cpu: Int?
        public var memoryMB: Int?
        public var diskMB: Int?

        public init(cpu: Int? = nil, memoryMB: Int? = nil, diskMB: Int? = nil) {
            self.cpu = cpu
            self.memoryMB = memoryMB
            self.diskMB = diskMB
        }

        /// "2 vCPU · 4 GB · 16 GB disk".
        public var summary: String {
            var parts: [String] = []
            if let cpu { parts.append(String(localized: "\(cpu) vCPU")) }
            if let memoryMB { parts.append(String(localized: "\(Self.gigabytes(memoryMB)) memory")) }
            if let diskMB { parts.append(String(localized: "\(Self.gigabytes(diskMB)) disk")) }
            return parts.joined(separator: " · ")
        }

        /// The Mac's new-machine default (`CloudMachineCreateFlow.named`): 2 vCPU, 4 GB, 16 GB disk.
        public static let newMachine = Size(cpu: 2, memoryMB: 4096, diskMB: 16384)

        static func gigabytes(_ mb: Int) -> String {
            mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024)
        }

        var json: [String: any Sendable] {
            var out: [String: any Sendable] = [:]
            if let cpu { out["cpu"] = cpu }
            if let memoryMB { out["memory_mb"] = memoryMB }
            if let diskMB { out["disk_mb"] = diskMB }
            return out
        }
    }

    public var id: String
    public var name: String?
    public var status: Status
    public var size: Size
    public var classic: Bool
    public var createdAt: Date?
    public var lastActiveAt: Date?
    public var idleSeconds: Int
    public var error: String?
    public var pauseReason: String?
    public var pausedBySpendCap: Bool
    public var hourlyRateUSD: Double?
    public var pausedHourlyRateUSD: Double?
    public var runningSince: Date?
    public var desktop: Bool
    public var evictAt: Date?
    public var keep: Bool

    public var title: String { name ?? id }
    public var idlePauseMinutes: Int { idleSeconds / 60 }

    /// The Mac's idle auto-pause choices (`CloudMachine.idlePauseChoices`), in minutes; 0 is Off.
    public static let idlePauseChoices = [0, 15, 30, 60, 120]

    /// The machines of a `cloud.machine.list` value, or one `cloud.machine.get` / `{machine}` value.
    public static func list(_ value: Data) -> [CloudMachine] {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] else { return [] }
        if let items = root["machines"] as? [[String: Any]] { return items.compactMap(parse) }
        if let item = root["machine"] as? [String: Any] { return parse(item).map { [$0] } ?? [] }
        return parse(root).map { [$0] } ?? []
    }

    static func parse(_ item: [String: Any]) -> CloudMachine? {
        guard let id = item["id"] as? String, let status = (item["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
        let size = item["size"] as? [String: Any] ?? [:]
        let error = item["error"] as? [String: Any]
        return CloudMachine(
            id: id, name: item["name"] as? String, status: status,
            size: Size(cpu: int(size["cpu"]), memoryMB: int(size["memory_mb"]), diskMB: int(size["disk_mb"])),
            classic: item["classic"] as? Bool ?? false,
            createdAt: CloudAutomation.milliseconds(item["created_at"]),
            lastActiveAt: CloudAutomation.milliseconds(item["last_active_at"]),
            idleSeconds: int((item["idle_policy"] as? [String: Any])?["idle_seconds"]) ?? 0,
            error: error.flatMap { $0["message"] as? String ?? $0["code"] as? String },
            pauseReason: item["pause_reason"] as? String,
            pausedBySpendCap: item["paused_by"] as? String == "spend_cap",
            hourlyRateUSD: (item["hourly_rate_usd"] as? NSNumber)?.doubleValue,
            pausedHourlyRateUSD: (item["paused_hourly_rate_usd"] as? NSNumber)?.doubleValue,
            runningSince: CloudAutomation.milliseconds(item["running_since"]),
            desktop: item["desktop"] as? Bool ?? false,
            evictAt: CloudAutomation.milliseconds(item["evict_at"]),
            keep: item["keep"] as? Bool ?? false)
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    /// What it costs, in words: "$0.12/hr · about $0.30 so far" running, "about $1.40 a month while paused".
    public func cost(now: Date) -> String? {
        switch status {
        case .running:
            guard let rate = hourlyRateUSD else { return nil }
            var text = String(localized: "\(rate.formatted(.currency(code: "USD"))) an hour")
            if let since = runningSince {
                let spent = rate * max(0, now.timeIntervalSince(since)) / 3600
                text += " · " + String(localized: "about \(spent.formatted(.currency(code: "USD"))) so far")
            }
            return text
        case .paused:
            guard let rate = pausedHourlyRateUSD else { return nil }
            return String(localized: "about \((rate * 730).formatted(.currency(code: "USD"))) a month while paused")
        default:
            return nil
        }
    }

    /// Why it is paused or failed, in the Mac's words.
    public var note: String? {
        if let error, status == .failed || status == .paused { return error }
        if pausedBySpendCap { return String(localized: "Paused at the team's spending cap.") }
        switch pauseReason {
        case "idle": return String(localized: "Paused after it sat idle.")
        case "no_report": return String(localized: "Paused: it stopped reporting.")
        case "provider_stopped", "provider_paused": return String(localized: "Paused from inside the machine.")
        default: return nil
        }
    }
}

/// A snapshot of a Cloud machine (`cloud.snapshot.list`), or an archive of a deleted one.
public struct CloudMachineSnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var machine: String
    public var name: String?
    public var sizeMB: Int
    public var status: String
    public var createdAt: Date?
    /// The deleted machine's name when this is its archive.
    public var archiveOf: String?
    public var archiveUntil: Date?

    public var title: String { name ?? archiveOf.map { String(localized: "Archive of \($0)") } ?? id }
    public var ready: Bool { status == "ready" }

    public static func list(_ value: Data) -> [CloudMachineSnapshot] {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let items = root["snapshots"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let machine = item["machine"] as? String else { return nil }
            let archive = item["archive_of"] as? [String: Any]
            return CloudMachineSnapshot(id: id, machine: machine, name: item["name"] as? String,
                                        sizeMB: CloudMachine.int(item["size_mb"]) ?? 0, status: item["status"] as? String ?? "ready",
                                        createdAt: CloudAutomation.milliseconds(item["created_at"]),
                                        archiveOf: archive.map { $0["name"] as? String ?? $0["machine"] as? String ?? "" },
                                        archiveUntil: CloudAutomation.milliseconds(archive?["until"]))
        }
        .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}

/// The team's Cloud plan (`cloud.plan.get`): its limits, the sizes it allows and this period's use.
public struct CloudMachinePlan: Hashable, Sendable {
    public var planID: String
    public var maxActive: Int
    public var maxSaved: Int
    public var memoryOptionsMB: [Int]
    public var lockedMemoryOptionsMB: [Int]
    public var hoursIncluded: Double?
    public var active: Int
    public var saved: Int
    public var hoursUsed: Double?

    public static func parse(_ value: Data) -> CloudMachinePlan? {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let plan = root["plan_id"] as? String else { return nil }
        let limits = root["limits"] as? [String: Any] ?? [:]
        let usage = root["usage"] as? [String: Any] ?? [:]
        let ints: (Any?) -> [Int] = { ($0 as? [NSNumber] ?? []).map(\.intValue) }
        return CloudMachinePlan(planID: plan, maxActive: CloudMachine.int(limits["max_active"]) ?? 0, maxSaved: CloudMachine.int(limits["max_saved"]) ?? 0,
                                memoryOptionsMB: ints(limits["memory_options_mb"]), lockedMemoryOptionsMB: ints(limits["locked_memory_options_mb"]),
                                hoursIncluded: (limits["vm_hours_included"] as? NSNumber)?.doubleValue,
                                active: CloudMachine.int(usage["active"]) ?? 0, saved: CloudMachine.int(usage["saved"]) ?? 0,
                                hoursUsed: (usage["vm_hours_used"] as? NSNumber)?.doubleValue)
    }

    /// The memory sizes a new machine may take on this plan (the Mac's default, 4 GB, when the
    /// plan lists none).
    public var memoryChoicesMB: [Int] {
        let open = memoryOptionsMB.filter { !lockedMemoryOptionsMB.contains($0) }
        return open.isEmpty ? [CloudMachine.Size.newMachine.memoryMB ?? 4096] : open.sorted()
    }
}

/// The Cloud Machines page's model (the Mac's Machines section, its Cloud machines): the
/// list and plan, and every machine action the Mac has (New, Start, Pause, Rename, Idle Pause,
/// Keep, Grow, Snapshots, Restore, Archive and Delete, Delete), each an op the account makes with
/// its own token (`/v1/read`, `/v1/ops`), never through a Mac.
@MainActor
@Observable
public final class CloudMachinesModel {
    public enum Phase: Equatable, Sendable {
        case loading, loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var machines: [CloudMachine] = []
    public private(set) var snapshots: [CloudMachineSnapshot] = []
    public private(set) var plan: CloudMachinePlan?
    /// The machine (or snapshot) an action runs on now; its row shows progress.
    public private(set) var busyID: String?
    /// A machine's page is up: its own alert shows a refusal, not the list's.
    public var showsDetail = false
    /// The last action's refusal, for an alert.
    public var failure: String?
    /// The last action's note ("Waiting for your approval in the Feed.").
    public var notice: String?

    @ObservationIgnored private let account: @MainActor () -> AccountCloud?
    @ObservationIgnored var newKey: () -> String = { UUID().uuidString.lowercased() }
    /// The DEBUG gallery's fixed page: it never reads the service.
    @ObservationIgnored var skipsLoad = false

    public init(account: @escaping @MainActor () -> AccountCloud?) {
        self.account = account
    }

    public static func live(_ sources: ChiefSources = .shared) -> CloudMachinesModel {
        CloudMachinesModel { [weak sources] in sources?.account }
    }

    public var canAct: Bool { busyID == nil && account() != nil }

    public func machine(_ id: String) -> CloudMachine? { machines.first { $0.id == id } }
    public func snapshots(of machine: String) -> [CloudMachineSnapshot] { snapshots.filter { $0.machine == machine && $0.archiveOf == nil } }
    /// Archives of deleted machines, restorable as new machines.
    public var archives: [CloudMachineSnapshot] { snapshots.filter { $0.archiveOf != nil } }

    /// Running first, then paused, then the rest; newest first inside each.
    public var sorted: [CloudMachine] {
        let rank: (CloudMachine.Status) -> Int = { [.running: 0, .starting: 1, .provisioning: 1, .pausing: 2, .paused: 3, .failed: 4, .deleting: 5][$0] ?? 6 }
        return machines.sorted { (rank($0.status), -($0.createdAt?.timeIntervalSince1970 ?? 0)) < (rank($1.status), -($1.createdAt?.timeIntervalSince1970 ?? 0)) }
    }

    public func load() async {
        if skipsLoad { return }
        guard let account = account() else {
            phase = .failed(String(localized: "Sign in to cmux to see your Cloud machines."))
            return
        }
        let before = phase
        if machines.isEmpty, phase != .loaded { phase = .loading }
        do {
            async let planned = account.read("cloud.plan.get")
            async let saved = account.read("cloud.snapshot.list")
            var rows: [CloudMachine] = []
            var cursor: String?
            repeat {
                var params: [String: any Sendable] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let page = try await account.read("cloud.machine.list", params: params)
                rows += CloudMachine.list(page)
                cursor = ((try? JSONSerialization.jsonObject(with: page)) as? [String: Any])?["next_cursor"] as? String
            } while cursor != nil && rows.count < 1000
            machines = rows
            // A plan or snapshot read that fails keeps the list (the page hides what it lacks).
            plan = (try? await planned).flatMap(CloudMachinePlan.parse) ?? plan
            if let value = try? await saved { snapshots = CloudMachineSnapshot.list(value) }
            phase = .loaded
        } catch is CancellationError {
            phase = before
        } catch {
            let message = Self.message(error)
            if machines.isEmpty { phase = .failed(message) } else { failure = message }
        }
    }

    // MARK: Actions

    /// New Cloud Machine: `cloud.machine.create {name, size}` (or from a snapshot).
    public func create(name: String, memoryMB: Int?, fromSnapshot: String? = nil) async {
        var size = CloudMachine.Size.newMachine
        if let memoryMB { size.memoryMB = memoryMB }
        var params: [String: any Sendable] = ["size": size.json]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { params["name"] = String(trimmed.prefix(80)) }
        if let fromSnapshot { params["from_snapshot"] = fromSnapshot }
        await act("new") { try await $0.mutate("cloud.machine.create", params: params, key: "create-\(self.newKey())") }
    }

    public func start(_ machine: CloudMachine) async {
        await act(machine.id, optimistic: { $0.status = .starting }) {
            try await $0.mutate("cloud.machine.start", params: ["machine": machine.id], key: "start-\(machine.id)-\(self.newKey())")
        }
    }

    public func pause(_ machine: CloudMachine) async {
        await act(machine.id, optimistic: { $0.status = .pausing }) {
            try await $0.mutate("cloud.machine.pause", params: ["machine": machine.id], key: "pause-\(machine.id)-\(self.newKey())")
        }
    }

    public func rename(_ machine: CloudMachine, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty, trimmed != machine.name else { return }
        await act(machine.id, optimistic: { $0.name = trimmed }) {
            try await $0.mutate("cloud.machine.rename", params: ["machine": machine.id, "name": trimmed], key: "rename-\(machine.id)-\(self.newKey())")
        }
    }

    /// Idle Pause: minutes idle before cmux Cloud pauses it; 0 is Off.
    public func setIdlePause(_ machine: CloudMachine, minutes: Int) async {
        await act(machine.id, optimistic: { $0.idleSeconds = minutes * 60 }) {
            try await $0.mutate("cloud.machine.idle_policy.set", params: ["machine": machine.id, "idle_seconds": minutes * 60],
                                key: "idle-\(machine.id)-\(self.newKey())")
        }
    }

    /// Keep: never deleted automatically (false lets the plan's cleanup apply again).
    public func setKeep(_ machine: CloudMachine, _ keep: Bool) async {
        await act(machine.id, optimistic: { $0.keep = keep }) {
            try await $0.mutate("cloud.machine.keep", params: ["machine": machine.id, "keep": keep], key: "keep-\(machine.id)-\(self.newKey())")
        }
    }

    /// Grow its memory (sizes only go up; the plan decides which are allowed).
    public func grow(_ machine: CloudMachine, memoryMB: Int) async {
        guard memoryMB > (machine.size.memoryMB ?? 0) else { return }
        var size = machine.size
        size.memoryMB = memoryMB
        await act(machine.id) {
            try await $0.mutate("cloud.machine.resize", params: ["machine": machine.id, "size": size.json], key: "resize-\(machine.id)-\(self.newKey())")
        }
    }

    public func delete(_ machine: CloudMachine) async {
        await act(machine.id, optimistic: { $0.status = .deleting }) {
            try await $0.mutate("cloud.machine.delete", params: ["machine": machine.id], key: "delete-\(machine.id)")
        }
    }

    /// Archive and Delete a paused or failed machine: its disk is kept as a restorable archive.
    public func archiveAndDelete(_ machine: CloudMachine) async {
        await act(machine.id, optimistic: { $0.status = .deleting }) {
            try await $0.mutate("cloud.machine.archive_delete", params: ["machine": machine.id], key: "archive-\(machine.id)")
        }
    }

    public func takeSnapshot(_ machine: CloudMachine, name: String) async {
        var params: [String: any Sendable] = ["machine": machine.id]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { params["name"] = String(trimmed.prefix(80)) }
        await act(machine.id) { try await $0.mutate("cloud.snapshot.create", params: params, key: "snapshot-\(machine.id)-\(self.newKey())") }
    }

    /// A new machine booted from a ready snapshot or archive.
    public func restore(_ snapshot: CloudMachineSnapshot) async {
        await act(snapshot.id) { try await $0.mutate("cloud.snapshot.restore", params: ["snapshot": snapshot.id], key: "restore-\(snapshot.id)-\(self.newKey())") }
    }

    public func deleteSnapshot(_ snapshot: CloudMachineSnapshot) async {
        let old = snapshots
        snapshots.removeAll { $0.id == snapshot.id }
        await act(snapshot.id, rollback: { [weak self] in self?.snapshots = old }) {
            try await $0.mutate("cloud.snapshot.delete", params: ["snapshot": snapshot.id], key: "snapshot-delete-\(snapshot.id)")
        }
    }

    /// Runs one op: the change shows at once (`optimistic`), the list is read again after, and a
    /// refusal puts the row back and says why. An approval the service holds is a note, not a failure.
    private func act(_ id: String, optimistic: ((inout CloudMachine) -> Void)? = nil, rollback: (() -> Void)? = nil,
                     _ work: @MainActor (AccountCloud) async throws -> Data) async {
        guard busyID == nil, let account = account() else {
            rollback?()
            return
        }
        let old = machines
        if let optimistic, let index = machines.firstIndex(where: { $0.id == id }) { optimistic(&machines[index]) }
        let restore = { [weak self] in
            self?.machines = old
            rollback?()
        }
        busyID = id
        notice = nil
        defer { busyID = nil }
        do {
            let value = try await work(account)
            // The op's own answer first ({machine} or {snapshot}), so the row is right before the list.
            for answered in CloudMachine.list(value) {
                if let index = machines.firstIndex(where: { $0.id == answered.id }) { machines[index] = answered } else { machines.append(answered) }
            }
            busyID = nil
            await load()
        } catch is CancellationError {
            restore()
        } catch let failure as AccountCloud.Failure where failure.code == "approval.pending" {
            restore()
            notice = String(localized: "Approve it in your Feed to finish.")
        } catch {
            restore()
            failure = Self.message(error)
        }
    }

    static func message(_ error: any Error) -> String {
        guard let failure = error as? AccountCloud.Failure else { return String(localized: "Couldn't reach cmux Cloud. Check your connection.") }
        switch failure.code {
        case "feature.disabled": return String(localized: "Your administrator turned off cmux Cloud, so Cloud machines are not shown.")
        case "auth.unauthenticated": return String(localized: "Sign in to cmux to see your Cloud machines.")
        case "cloud.plan.required": return String(localized: "Your plan doesn't include Cloud machines.")
        case "cloud.quota.exceeded": return String(localized: "You're at your plan's machine limit. Pause or delete one first.")
        case "cloud.size.locked": return String(localized: "Your plan doesn't allow that size.")
        case "cloud.size.grow_only": return String(localized: "A machine can only grow.")
        case "cloud.spend_cap.reached": return String(localized: "Your team reached its spending cap.")
        case "cloud.member_budget.reached": return String(localized: "You reached your monthly Cloud budget.")
        case "cloud.rate_limited": return String(localized: "Too many changes at once. Try again in a minute.")
        case "approval.denied": return String(localized: "The request was denied.")
        case "approval.expired": return String(localized: "The approval expired. Try again.")
        default: return failure.description
        }
    }
}

#if DEBUG
extension CloudMachinesModel {
    /// The page with fixed machines, plan and snapshots, for screenshots
    /// (`-cmux-mobile-recovery-gallery cloudmachines`). Its actions go nowhere.
    public static func gallery(now: Date = .now) -> CloudMachinesModel {
        let http = ChiefCloudHTTP(base: URL(fileURLWithPath: "/dev/null"), accessToken: { _ in "" })
        let model = CloudMachinesModel { AccountCloud(http: http) }
        model.skipsLoad = true
        let ago = { (seconds: TimeInterval) in now.addingTimeInterval(-seconds) }
        model.machines = [
            CloudMachine(id: "vm_gallery0000000000001", name: "Build box", status: .running, size: .init(cpu: 2, memoryMB: 8192, diskMB: 16384),
                         classic: false, createdAt: ago(86_400 * 3), lastActiveAt: ago(120), idleSeconds: 1800, error: nil, pauseReason: nil,
                         pausedBySpendCap: false, hourlyRateUSD: 0.11, pausedHourlyRateUSD: 0.002, runningSince: ago(5400), desktop: true,
                         evictAt: nil, keep: true),
            CloudMachine(id: "vm_gallery0000000000002", name: "Nightly evals", status: .paused, size: .newMachine,
                         classic: false, createdAt: ago(86_400 * 9), lastActiveAt: ago(86_400), idleSeconds: 900, error: nil, pauseReason: "idle",
                         pausedBySpendCap: false, hourlyRateUSD: 0.06, pausedHourlyRateUSD: 0.0015, runningSince: nil, desktop: false,
                         evictAt: now.addingTimeInterval(86_400 * 12), keep: false),
            CloudMachine(id: "vm_gallery0000000000003", name: "Repro sandbox", status: .starting, size: .newMachine,
                         classic: false, createdAt: ago(600), lastActiveAt: nil, idleSeconds: 0, error: nil, pauseReason: nil,
                         pausedBySpendCap: false, hourlyRateUSD: 0.06, pausedHourlyRateUSD: nil, runningSince: nil, desktop: false,
                         evictAt: nil, keep: false),
        ]
        model.plan = CloudMachinePlan(planID: "pro", maxActive: 3, maxSaved: 10, memoryOptionsMB: [4096, 8192, 16384, 32768],
                                      lockedMemoryOptionsMB: [32768], hoursIncluded: 200, active: 2, saved: 3, hoursUsed: 41.5)
        model.snapshots = [
            CloudMachineSnapshot(id: "snap_gallery00000000001", machine: "vm_gallery0000000000001", name: "Before Xcode 27", sizeMB: 6144,
                                 status: "ready", createdAt: ago(86_400 * 2), archiveOf: nil, archiveUntil: nil),
            CloudMachineSnapshot(id: "snap_gallery00000000002", machine: "vm_gallery0000000000009", name: nil, sizeMB: 3072,
                                 status: "ready", createdAt: ago(86_400 * 4), archiveOf: "Old staging box", archiveUntil: now.addingTimeInterval(86_400 * 26)),
        ]
        model.phase = .loaded
        return model
    }
}
#endif
