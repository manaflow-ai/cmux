import CmuxNextCloud
import CmuxNextCompat
import CmuxNextWakeups
public import Foundation
public import Observation

/// Where each chat runs and how its move to or from Cloud is going, as the chat's header shows it.
/// Swift only carries facts and draws: the move's state machine, its view (labels, budget, what
/// Cancel and Retry offer), Auto's rule, Evacuate's plan and the own-VM pick are Rust's
/// (`cloud_move_place_*`, cmux-tui/crates/cmux-cloud-start-core `moves/place.rs`). This store
/// reports each step of a move to that reducer, keeps its answer per session, and offers the
/// result to `pane.tabState` as `place`.
///
/// An FFI that has no `cloud_move_place_*` op (an app FFI pinned before the lane landed) answers
/// nil: the moves run as before, with no flow to show.
@MainActor @Observable
public final class CloudPlaceFlows {
    /// What a reduced event asks of the app.
    public enum Next: String { case go, stop, ignore }

    /// Who started a move, in the reducer's wire form (`person`, `evacuate`, `{"auto": reason}`).
    public enum Trigger: Equatable {
        case person, evacuate, auto(String)

        var json: Any {
            switch self {
            case .person: "person"
            case .evacuate: "evacuate"
            case .auto(let reason): ["auto": reason]
            }
        }

        /// The invocation argument that carries it (`trigger`): `person`, `evacuate` or `auto:<reason>`.
        public var argument: String {
            switch self {
            case .person: "person"
            case .evacuate: "evacuate"
            case .auto(let reason): "auto:" + reason
            }
        }

        public init(argument: String?) {
            switch argument {
            case "evacuate": self = .evacuate
            case let value? where value.hasPrefix("auto:"): self = .auto(String(value.dropFirst("auto:".count)))
            default: self = .person
            }
        }
    }

    /// What the chat carries, as the app reads it before the move starts (the reducer's `Cargo`).
    public struct Cargo: Equatable {
        public init() {}
        public var turnRunning = false
        public var continuesTurn = false
        /// Nil when the app has no reader for it: the key is left out, never sent as 0.
        public var queued: Int?
        public var hasDraft = false
        public var branch: String?
        /// Nil when the app has no reader for it: the key is left out, never sent as 0.
        public var dirtyFiles: Int?

        var json: [String: Any] {
            var cargo: [String: Any] = ["turnRunning": turnRunning, "continuesTurn": continuesTurn, "hasDraft": hasDraft]
            if let queued { cargo["queued"] = queued }
            if let dirtyFiles { cargo["dirtyFiles"] = dirtyFiles }
            if let branch { cargo["branch"] = branch }
            return cargo
        }
    }

    /// The reducer's op for one request and its reply bytes (`cloud_move_place_reduce`, `_view`); injected by tests.
    public typealias Core = @Sendable (_ operation: String, _ request: Data) -> Data?

    /// Each session's move as the chat draws it (the reducer's `View`, as JSON), set on every step.
    public private(set) var views: [String: Data] = [:]
    /// Each session's place mode (`local`, `cloud`, `auto`), kept across launches; none is Auto's default off.
    public private(set) var modes: [String: String] = [:]
    /// Each session Keep Running is on for (high priority, `priority::Priority::High`), with when it was turned on (Unix ms,
    /// the slot rule's `litAtMs`: the earliest keeps its slot), kept across launches; none is normal priority.
    public private(set) var priorities: [String: UInt64] = [:]
    /// Sessions whose move landed and whose card has had its moment: the header leaves its `move` out, so a remounted
    /// page never shows a finished move again. The view stays for Evacuate's rows; the next move's begin shows it again.
    public private(set) var settled: Set<String> = []

    /// Each session's flow, as the reducer last returned it.
    @ObservationIgnored private var flows: [String: Data] = [:]
    /// What stops each session's running move (its Task), set by the action that runs it.
    @ObservationIgnored private var stoppers: [String: () -> Void] = [:]
    /// Sessions whose move Cancel stopped: the stop is no failure and offers no Retry.
    @ObservationIgnored private var cancelled: Set<String> = []
    /// Sessions Auto moved to Cloud (so Auto may bring them back; a person's Cloud stays), kept across launches.
    @ObservationIgnored public private(set) var autoMoved: Set<String> = []
    /// Sessions Evacuate moved to Cloud and not back yet (Bring Back All's list with ``autoMoved``), kept across launches.
    @ObservationIgnored public private(set) var evacuated: Set<String> = []
    /// The Cloud machine each chat ran on before a Bring Back to this Mac ended its move-ledger entry, kept across launches:
    /// the next move to Cloud offers it to Rust's own-machine rule (`before`), so a Hybrid round trip resumes that machine
    /// instead of making another. One entry per chat brought back, dropped once a move to Cloud records it in the ledger again.
    @ObservationIgnored public private(set) var lastMachines: [String: String] = [:]
    /// The running (or last) Evacuate or Bring Back All; each change of it re-sends the header.
    public internal(set) var evacuation: Evacuation?
    /// Each running move's trigger and direction, to record who moved it once it landed.
    @ObservationIgnored private var started: [String: (auto: Bool, evacuate: Bool, toCloud: Bool)] = [:]
    /// Bumped once per change in the hybrid start drivers' folder; `placeJSON` reads it, so the header re-reads `start`.
    public private(set) var startRevision = 0
    /// The cmux-tui sessions folder (`CMUX_TUI_STATE_DIR`) the hybrid start drivers write under; nil reads no `start`.
    @ObservationIgnored private var startState: URL?
    /// Each session's `start` as of a revision, so a header read costs one FFI read per Show, not per read.
    @ObservationIgnored private var starts: [String: (revision: Int, start: Any?)] = [:]
    @ObservationIgnored private var startWatch: Task<Void, Never>?
    @ObservationIgnored private let core: Core
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let modesKey: String
    @ObservationIgnored private let clock: @Sendable () -> UInt64
    /// How long a landed move's card stays in the header after its work ended (the page's own linger, `MoveProgress.tsx`).
    @ObservationIgnored private let liveLinger: Duration
    /// Each chat's pending linger (``finished(_:)``); dropped once it fires.
    @ObservationIgnored private var lingers: [String: DemandTimer] = [:]

    public init(defaults: UserDefaults = .standard, key: String = "cmux.cloud.placeModes", core: Core? = nil, clock: (@Sendable () -> UInt64)? = nil,
                liveLinger: Duration = .milliseconds(2500)) {
        self.defaults = defaults
        self.liveLinger = liveLinger
        modesKey = key
        self.core = core ?? { operation, request in CloudStartCore().callData(operation, request) }
        self.clock = clock ?? { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
        if let kept = defaults.stringArray(forKey: key + ".autoMoved") { autoMoved = Set(kept) }
        if let kept = defaults.stringArray(forKey: key + ".evacuated") { evacuated = Set(kept) }
        // main-actor-ok: read once at launch; one session id and one short word per chat the person picked a mode for.
        if let data = defaults.data(forKey: key), let kept = try? JSONDecoder().decode([String: String].self, from: data) { modes = kept }
        // main-actor-ok: read once at launch; one session id and a timestamp per chat with Keep Running on.
        if let data = defaults.data(forKey: key + ".priority"), let kept = try? JSONDecoder().decode([String: UInt64].self, from: data) { priorities = kept }
        // main-actor-ok: read once at launch; one session id and machine id per chat brought back from Cloud.
        if let data = defaults.data(forKey: key + ".lastMachine"), let kept = try? JSONDecoder().decode([String: String].self, from: data) { lastMachines = kept }
    }

    /// This computer's own name, as the move names the place it leaves or reaches.
    public nonisolated static var thisMac: String { MacName().hostName() }

    /// Milliseconds on the monotonic clock every event of a flow is stamped with.
    public var nowMs: UInt64 { clock() }

    // MARK: Modes

    /// The mode the person picked; a chat with none runs where it is (a chat on Cloud reads Cloud, never Local).
    public func mode(of session: String, onCloud: Bool = false) -> String { modes[session] ?? (onCloud ? "cloud" : "local") }

    /// The choices a chat's place control offers (`place.modes`), from two settings, neither of which
    /// it changes. Settings > Experiments' Cloud Toggle (`experiments.cloudToggle`): Local, Cloud and
    /// Auto. Else AutoCloud (`cloud.autoCloud`, Settings > Machines): AutoCloud on or off for this one
    /// chat, Auto or Local, both ways while it lives. A chat with no pick stays Local: AutoCloud is an
    /// option per chat, never every chat's default (Leo, 2026-11-27: "we're not putting autocloud as
    /// THE DEFAULT OPTION FOR EVERY SINGLE CHAT. IT JUST SIMPLY MUST BE AN OPTION."; "we need to be
    /// able to toggle a chat on and off of autocloud"). Neither: none, and the control is hidden.
    public nonisolated static func offeredModes(cloudToggle: Bool, autoCloud: Bool) -> [String] {
        cloudToggle ? ["local", "cloud", "auto"] : autoCloud ? ["local", "auto"] : []
    }

    public func setMode(_ mode: String, of session: String) {
        guard ["local", "cloud", "auto"].contains(mode), modes[session] != mode else { return }
        modes[session] = mode
        // main-actor-ok: on the person's pick; one session id and one short word per chat the person picked a mode for.
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: modesKey) }
    }

    /// The chat's priority as the slot rule reads it: `high` with Keep Running on, else `normal`.
    public func priority(of session: String) -> String { priorities[session] == nil ? "normal" : "high" }

    /// `chatPriority.set`: Keep Running on (`high`) or off (`normal`); turning it on again keeps its first time.
    public func setPriority(_ priority: String, of session: String, nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        switch priority {
        case "high" where priorities[session] == nil: priorities[session] = nowMs
        case "normal" where priorities[session] != nil: priorities[session] = nil
        default: return
        }
        // main-actor-ok: on the person's toggle; one session id and a timestamp per chat with Keep Running on.
        if let data = try? JSONEncoder().encode(priorities) { defaults.set(data, forKey: modesKey + ".priority") }
    }

    // MARK: The machine a chat ran on

    /// A Bring Back of `session` (its id on this Mac) committed off `machineID`: kept for the chat's next move to Cloud.
    public func rememberMachine(_ machineID: String, for session: String) {
        guard lastMachines[session] != machineID else { return }
        lastMachines[session] = machineID
        saveLastMachines()
    }

    /// The machine `session` ran on before it was brought back, when it was.
    public func lastMachine(of session: String) -> String? { lastMachines[session] }

    /// The move ledger names the chat's machine again (a move to Cloud committed): this one is no longer needed.
    public func forgetMachine(of session: String) {
        guard lastMachines.removeValue(forKey: session) != nil else { return }
        saveLastMachines()
    }

    private func saveLastMachines() {
        // main-actor-ok: on a committed move; one session id and machine id per chat brought back from Cloud.
        if let data = try? JSONEncoder().encode(lastMachines) { defaults.set(data, forKey: modesKey + ".lastMachine") }
    }

    // MARK: Reporting a move

    /// The move starts at `preflight`.
    @discardableResult
    public func begin(session: String?, toCloud: Bool, trigger argument: String?, from: String, to: String, cargo: Cargo = .init()) -> Next {
        begin(session: session, toCloud: toCloud, trigger: Trigger(argument: argument), from: from, to: to, cargo: cargo)
    }

    @discardableResult
    public func begin(session: String?, toCloud: Bool, trigger: Trigger, from: String, to: String, cargo: Cargo = .init()) -> Next {
        guard let session else { return .go }
        flows[session] = nil
        cancelled.remove(session)
        settled.remove(session)
        started[session] = (auto: { if case .auto = trigger { true } else { false } }(), evacuate: trigger == .evacuate, toCloud: toCloud)
        return report(session, ["event": "begin", "session": session, "direction": toCloud ? "toCloud" : "toLocal", "trigger": trigger.json,
                                "from": from, "to": to, "cargo": cargo.json, "atMs": nowMs])
    }

    /// `step` starts (the steps before it are done).
    @discardableResult
    public func step(_ session: String?, _ step: String) -> Next { session.map { report($0, ["event": "step", "step": step, "atMs": nowMs]) } ?? .go }

    /// The machine got its name.
    @discardableResult
    public func target(_ session: String?, to name: String) -> Next { session.map { report($0, ["event": "target", "to": name]) } ?? .go }

    /// The chat runs on the new place.
    @discardableResult
    public func live(_ session: String?) -> Next {
        guard let session else { return .go }
        if let kind = started.removeValue(forKey: session) {
            // Auto may bring back only what Auto moved; a person's move either way ends that.
            if kind.auto && kind.toCloud { autoMoved.insert(session) } else { autoMoved.remove(session) }
            defaults.set(Array(autoMoved), forKey: modesKey + ".autoMoved")
            if kind.toCloud && kind.evacuate { evacuated.insert(session) } else { evacuated.remove(session) }
            defaults.set(Array(evacuated), forKey: modesKey + ".evacuated")
        }
        return report(session, ["event": "live", "atMs": nowMs])
    }

    @discardableResult
    public func failed(_ session: String?, reason: String) -> Next {
        guard let session else { return .go }
        started[session] = nil
        return report(session, ["event": "failed", "reason": reason, "atMs": nowMs])
    }

    /// A move the app refused before its first step (no chat there, a chat that cannot move yet): its flow begins and fails at
    /// once, so the chat shows the failure and its Retry instead of the mode it asked for with nothing moving.
    public func refused(_ session: String, toCloud: Bool, trigger: Trigger, reason: String) {
        begin(session: session, toCloud: toCloud, trigger: trigger, from: toCloud ? Self.thisMac : "", to: toCloud ? "" : Self.thisMac)
        failed(session, reason: reason)
    }

    /// The next step of the move. Throws ``CancellationError`` when the reducer says stop (a Cancel it honours at this boundary), for
    /// steps before the chat lands; once the chat committed, use ``step(_:_:)``, which never stops the move.
    public func advance(_ session: String?, _ step: String) throws {
        try Task.checkCancellation()
        guard let session else { return }
        guard self.step(session, step) != .stop else {
            cancelled.insert(session)
            throw CancellationError()
        }
    }

    /// The person pressed Cancel. When the reducer says `stop`, the move's Task is cancelled (the child
    /// processes die with it) and the chat stays where it was; past the last cancellable step the move finishes.
    @discardableResult
    public func cancel(_ session: String) -> Next {
        let next = report(session, ["event": "cancel", "atMs": nowMs])
        if next == .stop {
            cancelled.insert(session)
            stoppers[session]?()
        }
        return next
    }

    /// Whether Cancel ended the session's move (its stop shows no failure and keeps no Retry).
    public func wasCancelled(_ session: String?) -> Bool { session.map { cancelled.contains($0) } ?? false }

    /// Registers what stops the session's move; ends with ``finished(_:)``.
    public func onCancel(_ session: String?, _ stop: @escaping () -> Void) { if let session { stoppers[session] = stop } }

    /// The move's work ended (any way): its stopper goes. A move that landed leaves the header once its card has shown it
    /// (``settled``); a failed or cancelled one stays, with its Retry, until the next move begins.
    public func finished(_ session: String?) {
        guard let session else { return }
        stoppers[session] = nil
        started[session] = nil
        cancelled.remove(session)
        guard state(of: session) == "live" else { return }
        // One linger per chat: it settles the card unless the chat's next move runs (or failed) by then.
        let linger = lingers[session] ?? DemandTimer(owner: "cloudPlace.liveLinger")
        lingers[session] = linger
        linger.schedule(after: liveLinger) { @MainActor [weak self] in
            guard let self else { return }
            self.lingers[session] = nil
            guard self.state(of: session) == "live" else { return }
            self.settled.insert(session)
        }
    }

    /// Whether a flow of `session` is moving now (the reducer's own state, read from the kept view).
    public func isMoving(_ session: String) -> Bool { state(of: session) == "moving" }

    /// The session's view state (`moving`, `live`, `failed`, `cancelled`), nil with no flow.
    public func state(of session: String) -> String? {
        // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes (its view).
        guard let data = views[session], let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["state"] as? String
    }

    /// The session's last move as Rust's reducer drew it (its `View`: `state`, `step`, `elapsedMs` and `steps`, each finished
    /// step's ms), a landed one too: a settled card leaves only the header, not this. Nil with no move kept. `cloud.place.get`
    /// answers it, for the move journey probe's per-step times (`move_stages_ms`), which no move action's answer carries.
    public func moveView(of session: String) -> Any? {
        // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes (its view).
        views[session].flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Drops the session's flow and view (a Live move's card goes once the chat shows it).
    public func clear(_ session: String) {
        flows[session] = nil
        views[session] = nil
    }

    private func report(_ session: String, _ event: [String: Any]) -> Next {
        var request: [String: Any] = ["event": event]
        // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes.
        if let flow = flows[session], let object = try? JSONSerialization.jsonObject(with: flow) { request["flow"] = object }
        // main-actor-ok: the same one chat's flow plus one event.
        guard let body = try? JSONSerialization.data(withJSONObject: request), let reply = core("cloud_move_place_reduce", body),
              // main-actor-ok: the reducer's answer, that chat's next flow and one word.
              let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return .go }
        // The reducer answers `"flow": null` for an event with no move to fold into (it ignored it): keep what
        // was there. `data(withJSONObject:)` raises an uncatchable exception on a bare NSNull (review of #51824, F1).
        guard let flow = answer["flow"] as? [String: Any], JSONSerialization.isValidJSONObject(flow),
              // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes.
              let kept = try? JSONSerialization.data(withJSONObject: flow) else {
            return (answer["next"] as? String).flatMap(Next.init(rawValue:)) ?? .go
        }
        flows[session] = kept
        let nowMs = nowMs
        // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes and a clock reading.
        if let viewRequest = try? JSONSerialization.data(withJSONObject: ["flow": flow, "nowMs": nowMs] as [String: Any]),
           let view = core("cloud_move_place_view", viewRequest) {
            views[session] = view
        }
        return (answer["next"] as? String).flatMap(Next.init(rawValue:)) ?? .go
    }

    // MARK: A hybrid start's state (RFD 0078 "the start")

    /// Reads each chat's hybrid start from the drivers under `state` (Rust's `cloud_hybrid_start`), re-read
    /// once per Show: a driver renames its `<session>.show` into `hybrid-start/` after each one, so a folder
    /// watch there wakes once per state and nothing polls.
    public func watchStarts(state: URL?) {
        guard state != startState || (state != nil && startWatch == nil) else { return }
        startState = state
        startWatch?.cancel()
        startWatch = nil
        startRevision &+= 1 // what was read under another folder (or none) is stale
        guard let state else { return }
        // The drivers' folder sits beside the sessions folder (cmux-cloud-start-core `hybrid_show`).
        let folder = state.deletingLastPathComponent().appending(path: "hybrid-start", directoryHint: .isDirectory)
        startWatch = Task { @MainActor [weak self] in
            for await _ in await FolderChanges(folders: [folder]).events() {
                guard let self else { return }
                startRevision &+= 1
            }
        }
    }

    /// The session's `start` (`{cloud, reason?, sinceMs?}`), as Rust reads its driver's newest Show; nil with none.
    func start(of session: String) -> Any? {
        let revision = startRevision
        if let kept = starts[session], kept.revision == revision { return kept.start }
        var start: Any?
        // main-actor-ok: once per Show per chat; a folder path and a session id.
        if let startState, let request = try? JSONSerialization.data(withJSONObject: ["stateDir": startState.path, "session": session]),
           let reply = core("cloud_hybrid_start", request),
           // main-actor-ok: that chat's `{start: {cloud, reason?, sinceMs?}}`.
           let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           let value = answer["start"] as? [String: Any], JSONSerialization.isValidJSONObject(value) {
            start = value
        }
        starts[session] = (revision, start)
        return start
    }

    // MARK: The chat's place, for pane.tabState

    /// `place: {mode, at, cloudName?, move?, blocked?, holders?, keep?, start?}` for the chat header, as JSON; nil with no session.
    /// `blocked`, `holders` and `keep` (Keep Running's lit, used, total, waiting) are Rust's answer (`cloud_move_place_control`, `priority::control`) to `control`'s facts.
    /// `starts`: the sessions folder whose hybrid start drivers say `start` (watched from the first read on).
    /// `modes`: the choices its control offers (``offeredModes(cloudToggle:autoCloud:)``); nil leaves them out.
    public func placeJSON(session: String?, onCloud: Bool, cloudName: String?, control: ControlFacts? = nil, starts state: URL? = nil,
                          modes offered: [String]? = nil) -> Data? {
        if let state { watchStarts(state: state) }
        guard let session else { return nil }
        var place: [String: Any] = ["mode": mode(of: session, onCloud: onCloud), "at": onCloud ? "cloud" : "local"]
        if let offered { place["modes"] = offered }
        if let cloudName { place["cloudName"] = cloudName }
        // main-actor-ok: one chat's move reducer state, a fixed-shape object of a few hundred bytes (its view).
        if !settled.contains(session), let view = views[session], let move = try? JSONSerialization.jsonObject(with: view) { place["move"] = move }
        // main-actor-ok: one row of eight scalars per open chat, sent only signed in with a plan.
        if let control, let request = try? JSONEncoder().encode(control.with(session: session)), let reply = core("cloud_move_place_control", request),
           // main-actor-ok: Rust's `{blocked, holders, keep}` for this chat's control.
           let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
            if let blocked = answer["blocked"] { place["blocked"] = blocked }
            if let holders = answer["holders"] { place["holders"] = holders }
            if let keep = answer["keep"] { place["keep"] = keep }
        }
        if let start = start(of: session) { place["start"] = start }
        if let status = computerStatus(session: session, place: place) { place["status"] = status }
        // main-actor-ok: this one chat's header place; the order is read: AgentPaneHeaderState compares placeData bytes.
        return try? JSONSerialization.data(withJSONObject: place, options: [.sortedKeys])
    }

    /// The chat's one `ComputerStatus` (RFD 0080's status line and popover rows), as Rust folds `place`'s `at`, `move` and
    /// `start` (`cloud_computer_status_live`), with the app's two clocks while a move is in it; nil when Rust answers nothing.
    func computerStatus(session: String, place: [String: Any]) -> Any? {
        var facts: [String: Any] = ["session": session]
        for key in ["at", "move", "start"] { if let value = place[key] { facts[key] = value } }
        // A move is stamped on `nowMs` (uptime); the page counts on Unix ms. Rust puts the stamps on Unix ms.
        if facts["move"] != nil { facts["clock"] = ["monoMs": nowMs, "wallMs": UInt64(Date().timeIntervalSince1970 * 1000)] }
        // main-actor-ok: the chat's at, move and start facts, three small objects, once per header read.
        guard JSONSerialization.isValidJSONObject(facts), let request = try? JSONSerialization.data(withJSONObject: facts),
              let reply = core("cloud_computer_status_live", request) else { return nil }
        // main-actor-ok: Rust's one ComputerStatus for this chat (a status line and a few popover rows).
        return try? JSONSerialization.jsonObject(with: reply)
    }

    /// What Rust needs to say whether the header's cloud control is blocked or every slot is held (`priority::ControlFacts`).
    /// Facts only: a plan id is mapped to its slots in Rust (`priority::plan_of_id`); a plan not read is `planKnown: false`.
    public struct ControlFacts: Encodable, Sendable, Equatable {
        public struct Chat: Encodable, Sendable, Equatable {
            public var session: String, title: String, pin: String, at: String, hasWork: Bool, activeAtMs: UInt64
            public var priority: String, litAtMs: UInt64?
            public init(session: String, title: String, pin: String, at: String, hasWork: Bool, activeAtMs: UInt64 = 0,
                        priority: String = "normal", litAtMs: UInt64? = nil) {
                (self.session, self.title, self.pin, self.at, self.hasWork, self.activeAtMs) = (session, title, pin, at, hasWork, activeAtMs)
                (self.priority, self.litAtMs) = (priority, litAtMs)
            }
        }
        public var session = "", signedIn: Bool, restoring: Bool, planKnown: Bool, planId: String?, chats: [Chat]
        public init(signedIn: Bool, restoring: Bool, planKnown: Bool, planId: String?, chats: [Chat]) {
            (self.signedIn, self.restoring, self.planKnown, self.planId, self.chats) = (signedIn, restoring, planKnown, planId, chats)
        }
        func with(session: String) -> Self { var copy = self; copy.session = session; return copy }
    }

    /// The header control's facts (``ControlFacts``): `planId` is nil while no read kept a plan with an id (Rust would read a
    /// kept plan with no id as no plan at all), so a plan not read never claims No Plan or a full slot list; `chats` is read
    /// only when Rust will count slots (signed in, plan kept): a header with no plan never walks every tab.
    public func controlFacts(signedIn: Bool, restoring: Bool, planId: String?, chats: () -> [CloudPlaceChat]) -> ControlFacts {
        ControlFacts(signedIn: signedIn, restoring: restoring, planKnown: planId != nil, planId: planId, chats: planId == nil ? [] : controlChats(chats()))
    }

    /// ``ControlFacts/Chat`` for each chat the place controls see, pinned as the person set it here.
    public func controlChats(_ chats: [CloudPlaceChat]) -> [ControlFacts.Chat] {
        chats.map { chat in
            ControlFacts.Chat(session: chat.session, title: chat.title, pin: mode(of: chat.session, onCloud: chat.onCloud), at: chat.onCloud ? "cloud" : "local",
                              hasWork: chat.turnRunning || chat.queued > 0, activeAtMs: chat.turnStartedAtMs.flatMap { $0.isFinite && $0 > 0 ? UInt64($0) : nil } ?? 0,
                              priority: priority(of: chat.session), litAtMs: priorities[chat.session])
        }
    }
}
