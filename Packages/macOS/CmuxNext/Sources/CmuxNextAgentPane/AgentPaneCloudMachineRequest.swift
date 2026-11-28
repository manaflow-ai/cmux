public import CmuxNextCloud
public import Foundation

/// The signed-in account's Cloud machines in the composer's environment picker, beside the peers
/// acpmux lists: a paused machine, or one the local acpmux has no link to, still shows with its
/// state, and the person can resume or open it from there. Fixed param keys (any other is
/// refused); a machine id is checked here and again by the App against the machines it loaded.
///
/// - `cloudMachine.list {}` -> `{signedIn, loaded, machines: [{id, name, stage, evictAt?, size?: {cpu?, memoryMb?, diskMb?}}], lastSeenAt?}`, read-only.
///   `lastSeenAt` (epoch ms) marks a list kept from an earlier launch, shown before the first fresh one lands.
///   `cloudMachine.list {fresh: true}` (``freshList``) reads the Cloud plan again, past the kept read: a Send the plan
///   would hold, and the pricing card's re-read back from checkout, never act on a minute-old plan. On a cold start it
///   also waits for a fresh machine read (``freshList``) rather than answering the kept list: Retry and a pick of a kept row.
///   `stage` is the machine's `CloudMachineStage` name (`ready`, `paused`, `connecting`, …);
///   `loaded` is false until the App holds a list the server answered for the account signed in.
/// - `cloudMachine.recoveryList {}` -> the same inventory, refreshed for a disconnected chat.
///   `complete` is true only when the App's list is an authoritative answer (for the recovery
///   list: this read's own refresh landed), so a machine absent from it was deleted.
/// - `cloudMachine.open {id}` -> `{}`: Open Machine (its first workspace; a paused one resumes).
/// - `cloudMachine.resume {id}` -> `{}`: Resume Machine, for a paused machine only.
/// - `cloudMachine.attach {id}` -> `{}`: resume a paused chat machine without opening a workspace;
///   the App reads the machine again first, and one that turned live is attached, not resumed.
/// - `cloudMachine.pause {id}` -> `{}`: Pause Machine, for a running machine only (the chat menu
///   of a chat on that machine, cmuxterm-hq#4755).
/// - `cloudMachine.delete {id}` -> `{}`: Delete Machine… in the chat menu: the App's Kill Machine,
///   which asks the person first (its confirmation sheet) and deletes only on their answer.
/// - `cloudMachine.prewarm {id}` -> `{}`: a passive typing hint; wakes a loaded paused machine
///   through the predictive/script route and never consumes a user gesture.
/// - `cloudMachine.wakeHint {v, id, signal}` -> `{resume}`: wake on intent (v1): the page or shell saw
///   the person focus that machine's chat, open a terminal on it or unlock with it in front, before any
///   key. The App only forwards it; Rust decides (`cloud_handler_wake_hint`, cmux-cloud-handlers
///   `wake_hint`): hidden setting `cloud.wakeOnIntent` (default on; the setting is the kill switch), paused machines only, debounced,
///   capped, and re-paused when no input follows. Never a gesture. A host without it answers
///   `unsupported`, which the page drops; a page without it never sends one.
///
/// Open, Resume, Attach, Pause and Delete change a machine: each takes the person's own click (one gesture;
/// Attach its scope-add credit, so the Enter of a prompt that wakes the machine still sends it).
public nonisolated enum AgentPaneCloudMachineRequest: Equatable, Sendable {
    case list
    /// The list with the Cloud plan read again (`fresh: true`), not the kept read (``AgentPaneCloudPlanReads``).
    case freshList
    case recoveryList
    case open(id: String)
    case resume(id: String)
    case attach(id: String)
    case pause(id: String)
    case delete(id: String)
    case prewarm(id: String)
    /// Wake on intent: `version` is the sender's (`v`), `signal` the raw event name Rust reads.
    case wakeHint(id: String, signal: String, version: Int)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = [
        "cloudMachine.list", "cloudMachine.recoveryList", "cloudMachine.open", "cloudMachine.resume", "cloudMachine.attach", "cloudMachine.pause", "cloudMachine.delete", "cloudMachine.prewarm",
        "cloudMachine.wakeHint",
    ]
    /// Longest id the page may send back (the API's ids are far shorter).
    static let maximumIDLength = 128
    /// Most rows one list answers.
    static let maximumListed = 200

    /// The request for `method` and `params`, nil when they break the contract.
    init?(method: String, params: [String: Any]?) {
        let params = params ?? [:]
        switch method {
        case "cloudMachine.list" where Set(params.keys) == ["fresh"]:
            guard let fresh = params["fresh"] as? Bool else { return nil }
            self = fresh ? .freshList : .list
        case "cloudMachine.list", "cloudMachine.recoveryList":
            guard params.isEmpty else { return nil }
            self = method == "cloudMachine.list" ? .list : .recoveryList
        case "cloudMachine.open", "cloudMachine.resume", "cloudMachine.attach", "cloudMachine.pause", "cloudMachine.delete", "cloudMachine.prewarm":
            guard Set(params.keys) == ["id"], let id = Self.machineID(params["id"]) else { return nil }
            switch method {
            case "cloudMachine.open": self = .open(id: id)
            case "cloudMachine.resume": self = .resume(id: id)
            case "cloudMachine.attach": self = .attach(id: id)
            case "cloudMachine.prewarm": self = .prewarm(id: id)
            case "cloudMachine.delete": self = .delete(id: id)
            default: self = .pause(id: id)
            }
        case "cloudMachine.wakeHint":
            // A newer page may add fields: the known three decide, the rest are ignored.
            guard let id = Self.machineID(params["id"]), let version = params["v"] as? Int, version >= 1,
                  let signal = params["signal"] as? String, Self.isSignalName(signal) else { return nil }
            self = .wakeHint(id: id, signal: signal, version: version)
        default:
            return nil
        }
    }

    /// A raw signal name: 1-32 ASCII letters. Which ones count is Rust's.
    static func isSignalName(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 32 && raw.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
    }

    /// A machine id as the page sends it back: ASCII letters, digits, `-`, `_`, `.` and `:`.
    static func machineID(_ raw: Any?) -> String? {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= maximumIDLength,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) })
        else { return nil }
        return id
    }

    var method: String {
        switch self {
        case .recoveryList: "cloudMachine.recoveryList"
        case .list, .freshList: "cloudMachine.list"
        case .open: "cloudMachine.open"
        case .resume: "cloudMachine.resume"
        case .attach: "cloudMachine.attach"
        case .pause: "cloudMachine.pause"
        case .delete: "cloudMachine.delete"
        case .prewarm: "cloudMachine.prewarm"
        case .wakeHint: "cloudMachine.wakeHint"
        }
    }
}

/// The App's side of `cloudMachine.*`: App-wide, like the account it reads. CmuxNextApp makes one,
/// sets its closures and hands it to every pane (``AgentPaneModel/cloudMachines``); a test uses its
/// own instance. Unset, every method is refused.
@MainActor
public final class AgentPaneCloudMachines {
    /// How old the App's machine list may be when a picker reads it: an open picker reads every
    /// few seconds, the server's list at most this often (the store also follows each machine's
    /// own link between reads).
    public static let listAge: Duration = .seconds(60)

    /// One Cloud machine as the picker lists it.
    public struct Machine: Equatable, Sendable {
        public var id: String
        public var name: String
        /// The machine's `CloudMachineStage` name.
        public var stage: String
        /// When the server deletes the machine if it stays paused (cmux-platform `evict_at`); nil
        /// when the record does not say.
        public var evictAt: Date?
        /// The machine's size as its record says it (``CloudMachine/Size``); nil when it says none.
        /// The composer's machine card names it (webviews MachineCard.tsx).
        public var size: Size?
        /// The workspace registry shared by this VM's app and acpmux links.
        public var cloudRegistryID: String?
        public init(id: String, name: String, stage: String, evictAt: Date? = nil, size: Size? = nil, cloudRegistryID: String? = nil) {
            (self.id, self.name, self.stage, self.evictAt, self.size) = (id, name, stage, evictAt, size)
            self.cloudRegistryID = cloudRegistryID
        }

        /// vCPUs, memory and disk; each nil when the record does not say.
        public struct Size: Equatable, Sendable {
            public var cpu: Int?
            public var memoryMb: Int?
            public var diskMb: Int?
            public init(cpu: Int? = nil, memoryMb: Int? = nil, diskMb: Int? = nil) {
                (self.cpu, self.memoryMb, self.diskMb) = (cpu, memoryMb, diskMb)
            }

            /// From a record's size; nil when it names none of the three.
            public init?(_ size: CloudMachine.Size?) {
                guard let size, size.cpu != nil || size.memoryMb != nil || size.storageMb != nil else { return nil }
                self.init(cpu: size.cpu, memoryMb: size.memoryMb, diskMb: size.storageMb)
            }

            /// The reply's `size` object: only the positive numbers the record gave.
            var reply: [String: Any] {
                var row: [String: Any] = [:]
                for (key, value) in [("cpu", cpu), ("memoryMb", memoryMb), ("diskMb", diskMb)] {
                    if let value, value > 0 { row[key] = value }
                }
                return row
            }
        }
    }

    /// The account's machines, as the App holds them now.
    public struct Inventory: Equatable, Sendable {
        public var signedIn: Bool
        public var loaded: Bool
        public var machines: [Machine]
        public var account: [String?]?
        /// Whether the list is the server's answer for this read: a machine absent from a complete
        /// list is gone. A failed, superseded or merely cached read is not complete.
        public var complete: Bool
        /// The team Cloud works in (the active team): its name, and whether it is the person's own.
        /// The page keeps it for diagnostics; the Cloud row and face say only Cloud (cmux issue 45695).
        public var team: Team?
        /// The account's teams as the team menu lists them (`teams` of the reply): the page names a
        /// team only when it is one of these (webviews TeamTag.tsx `activeTeamFromReply`).
        public var teams: [Team]
        /// The Cloud plan as the server answered it (``Plan``); `unknown` when nothing was read.
        public var plan: Plan
        /// When `machines` is the list kept from an earlier launch (cmux-cloud-machine `last_seen`), the time
        /// the server answered it: the page marks those rows last seen until a fresh list lands. Nil for a fresh list.
        public var lastSeenAt: Date?
        public init(signedIn: Bool, loaded: Bool, machines: [Machine], account: [String?]? = nil, complete: Bool = false,
                    team: Team? = nil, teams: [Team] = [], plan: Plan = .unknown, lastSeenAt: Date? = nil) {
            (self.account, self.complete, self.team, self.teams, self.plan, self.lastSeenAt) = (account, complete, team, teams, plan, lastSeenAt)
            (self.signedIn, self.loaded, self.machines) = (signedIn, loaded, machines)
        }
    }

    /// A team as the page reads it (`team` and each of `teams` of a `cloudMachine.list` reply).
    public struct Team: Equatable, Sendable {
        public var id: String?
        public var name: String
        public var personal: Bool
        public init(id: String? = nil, name: String, personal: Bool) {
            (self.id, self.name, self.personal) = (id, name, personal)
        }

        var reply: [String: Any] {
            var value: [String: Any] = ["name": name, "personal": personal]
            if let id { value["id"] = id }
            return value
        }
    }

    public var list: (@MainActor () async -> Inventory)?
    /// The list for `cloudMachine.list {fresh: true}`: on a cold start it waits for a fresh read instead
    /// of answering the kept list at once (``CloudLastSeenMachines``), so Retry and a pick of a kept row
    /// act on what the server says now. Nil: ``list``.
    public var freshList: (@MainActor () async -> Inventory)?
    /// Fresh inventory for a disconnected chat; avoids the picker cache hiding a paused machine.
    public var recoveryList: (@MainActor () async -> Inventory)?
    /// What Resume machine on an unavailable chat does, decided on a fresh read of the machine:
    /// the recovery list that offered it may be a minute old, and a machine that turned live since
    /// must not be resumed again.
    public enum RecoveryAttach: Equatable {
        /// Paused: ``CloudMachineSession/attach(origin:)``, which resumes it through Resume Machine's path.
        case resume
        /// Live without a connection: connect it (an app link connects; a legacy daemon is woken or
        /// connected again). ``CloudMachineSession/attach(origin:)`` only resumes a paused legacy
        /// machine, so it would do nothing here.
        case connect
        /// Live and connected: nothing to do; the chat reopens when it lists.
        case connected
        /// The read failed, or the machine is gone or failed.
        case refuse
    }

    public static func recoveryAttach(fresh: Bool, status: CloudMachine.Status?, connected: Bool) -> RecoveryAttach {
        guard fresh, let status else { return .refuse }
        if status == .paused { return .resume }
        guard status.isLive else { return .refuse }
        return connected ? .connected : .connect
    }

    /// Refreshes, then reads the machine, then resumes or connects only on what that fresh read says.
    public static func recoveryAttach(
        refresh: @MainActor () async -> Bool,
        machine: @MainActor () -> (status: CloudMachine.Status, connected: Bool)?,
        resume: @MainActor () -> Void,
        connect: @MainActor () -> Void
    ) async -> Bool {
        let fresh = await refresh()
        let read = machine()
        switch recoveryAttach(fresh: fresh, status: read?.status, connected: read?.connected ?? false) {
        case .resume:
            resume()
            return true
        case .connect:
            connect()
            return true
        case .connected:
            return true
        case .refuse:
            return false
        }
    }

    /// A typing prewarm (``prewarm``) is a hint: it resumes (`resume`, script-originated) only a paused machine of the
    /// loaded list while the App may call Cloud (`allowed`). True once the resume was accepted.
    public static func prewarmIfPaused(allowed: Bool, status: CloudMachine.Status?, resume: @MainActor () async throws -> Void) async -> Bool {
        guard allowed, status == .paused else { return false }
        return (try? await resume()) != nil
    }

    /// Runs Open Machine on a machine of the loaded list; false when it is not one.
    public var open: (@MainActor (String) -> Bool)?
    /// Runs Resume Machine on a paused machine of the loaded list; false otherwise.
    public var resume: (@MainActor (String) -> Bool)?
    /// Attaches without opening another workspace, including the app-server resume route.
    public var attach: (@MainActor (String) async -> Bool)?
    /// Runs Pause Machine on a running machine of the loaded list; false otherwise.
    public var pause: (@MainActor (String) -> Bool)?
    /// Runs Kill Machine (its confirmation first) on a machine of the loaded list; false otherwise.
    public var delete: (@MainActor (String) -> Bool)?
    /// Sends a passive predictive wake hint to a paused machine of the loaded list; false otherwise.
    /// Unlike user actions, this never consumes a page gesture.
    public var prewarm: (@MainActor (String) async -> Bool)?
    /// Forwards a wake-on-intent hint (machine, raw signal, sender version) to the rules; true when it
    /// resumed the machine. Never a gesture.
    public var wakeHint: (@MainActor (String, String, Int) async -> Bool)?

    /// A raw wake-on-intent signal the Mac shell saw (a paused machine's terminal tab shown), sent like
    /// the page's `cloudMachine.wakeHint`; the rules (debounce, cap, re-pause) are Rust's.
    public func intent(_ id: String, signal: String) {
        guard let wakeHint else { return }
        // task-owner: one hint; the rules answer at once and the resume is bounded by its own Cloud call
        Task { _ = await wakeHint(id, signal, AgentPaneCloudWakeOnIntent.version) }
    }
    /// What follows the account's active team for ``publishTeamChange()``; a new one replaces it.
    public var teamWatch: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    /// The account's last Cloud plan read (``Plan``), reused for a minute: the list's `plan`.
    public let planReads = AgentPaneCloudPlanReads()

    /// How old the account's team list may be when a picker reads the machines. The App read it only
    /// at sign-in and restore, so a team the account was removed from elsewhere stayed on the Cloud
    /// face and in the start until relaunch (a saved selection falls back to the account's own team
    /// only once the list is read again, `AuthCoordinator.resolvedTeamID`).
    public static let teamsAge: Duration = .seconds(60)
    private var teamsReadAt: ContinuousClock.Instant?

    /// Runs `read` (the App's team-list read) when the last one started more than ``teamsAge`` ago;
    /// the list reply does not wait for it, and a change reaches every page through ``teamWatch``.
    /// True when it started one.
    @discardableResult
    public func readTeamsIfOld(now: ContinuousClock.Instant = .now, read: @escaping @MainActor () async -> Void) -> Bool {
        if let at = teamsReadAt, now >= at, at.duration(to: now) < Self.teamsAge { return false }
        teamsReadAt = now
        // task-owner: one bounded team-list read (AuthCoordinator's network timeout), at most one per teamsAge
        Task { await read() }
        return true
    }

    public init() {}

    /// What each page of these machines runs on a team change: its composer reads `cloudMachine.list`
    /// again, so the Cloud row names the new team at once.
    public static let teamChangeScript = "window.dispatchEvent(new Event('cmux-cloud-team-change'))"

    private struct Page { weak var model: AgentPaneModel? }
    /// The panes handed these machines (``AgentPaneModel/cloudMachines``), held weakly.
    private var pages: [Page] = []

    /// Adds `model` to the panes a team change reaches; a closed pane's entry goes at the next add.
    func follow(_ model: AgentPaneModel) {
        pages.removeAll { $0.model == nil || $0.model === model }
        pages.append(Page(model: model))
    }

    /// Tells every pane of these machines that the account's active team changed.
    public func publishTeamChange() {
        for page in pages { page.model?.onCloudTeamChange?() }
    }
}

extension AgentPaneCloudMachineRequest {
    /// The page's reply. Open, Resume and Pause consume one gesture, and only once the App can run them.
    @MainActor
    func reply(_ machines: AgentPaneCloudMachines?, gestures: AgentPaneUserGestures) async -> [String: Any] {
        switch self {
        case .list, .freshList, .recoveryList:
            let read = switch self {
            case .recoveryList: machines?.recoveryList
            case .freshList: machines?.freshList ?? machines?.list
            default: machines?.list
            }
            guard let list = read else { return AgentPaneModel.unsupported(method) }
            if self == .freshList { machines?.planReads.forget() }
            let inventory = await list()
            let rows: [[String: Any]] = inventory.machines.prefix(Self.maximumListed).map { machine in
                var row: [String: Any] = ["id": machine.id, "name": machine.name, "stage": machine.stage]
                // Epoch ms, as the page reads it (cloudMachines.ts `evictAt`).
                if let evictAt = machine.evictAt { row["evictAt"] = (evictAt.timeIntervalSince1970 * 1000).rounded() }
                // vCPUs, memory and disk (cloudMachines.ts `size`), for the composer's machine card.
                if let size = machine.size?.reply, !size.isEmpty { row["size"] = size }
                if let id = machine.cloudRegistryID { row["cloudRegistryId"] = id }
                return row
            }
            var value: [String: Any] = ["signedIn": inventory.signedIn, "loaded": inventory.loaded, "machines": rows, "complete": inventory.complete && inventory.machines.count <= Self.maximumListed]
            if let account = inventory.account { value["account"] = account.map { $0 as Any? ?? NSNull() } }
            if inventory.signedIn, let team = inventory.team { value["team"] = team.reply }
            if inventory.signedIn, !inventory.teams.isEmpty { value["teams"] = inventory.teams.map(\.reply) }
            value["plan"] = (inventory.signedIn ? inventory.plan : .unknown).reply
            // Epoch ms (cloudMachines.ts `lastSeenAt`); a kept list is never complete.
            if let lastSeenAt = inventory.lastSeenAt { value["lastSeenAt"] = (lastSeenAt.timeIntervalSince1970 * 1000).rounded(); value["complete"] = false }
            return AgentPaneReply.success(value)
        case .open(let id): return run(machines?.open, on: id, gestures: gestures)
        case .resume(let id): return run(machines?.resume, on: id, gestures: gestures)
        case .attach(let id):
            guard let attach = machines?.attach else { return AgentPaneModel.unsupported(method) }
            // The gesture's scope-add credit, not its grant: a send in a chat whose machine is
            // paused wakes it with the Enter that sent the prompt, and the prompt then goes with
            // that Enter's grant once the chat is back (webviews cloudWake.ts).
            guard gestures.consumeScope() else { return AgentPaneModel.transportFailure(.gestureRequired) }
            guard await attach(id) else { return Self.notRun(method) }
            return AgentPaneReply.success()
        case .pause(let id): return run(machines?.pause, on: id, gestures: gestures)
        case .delete(let id): return run(machines?.delete, on: id, gestures: gestures)
        case .prewarm(let id):
            guard let prewarm = machines?.prewarm else { return AgentPaneModel.unsupported(method) }
            guard await prewarm(id) else { return Self.notRun(method) }
            return AgentPaneReply.success()
        case .wakeHint(let id, let signal, let version):
            guard let wakeHint = machines?.wakeHint else { return AgentPaneModel.unsupported(method) }
            // A skipped hint is an answer, not a failure: the page never retries a hint.
            return AgentPaneReply.success(["resume": await wakeHint(id, signal, version)])
        }
    }

    private static func notRun(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unavailable", message: "The app did not run \(method) on that Cloud machine.")
    }

    @MainActor
    private func run(_ action: (@MainActor (String) -> Bool)?, on id: String, gestures: AgentPaneUserGestures) -> [String: Any] {
        guard let action else { return AgentPaneModel.unsupported(method) }
        guard gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        guard action(id) else { return Self.notRun(method) }
        return AgentPaneReply.success()
    }
}
