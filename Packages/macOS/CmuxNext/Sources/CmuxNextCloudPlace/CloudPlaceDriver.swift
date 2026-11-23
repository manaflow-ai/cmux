import CmuxNextCloud
import CmuxNextWakeups
import Foundation

/// One chat as the place controls see it, read by the app (``CloudPlaceHost``).
public struct CloudPlaceChat: Sendable {
    public var id: String, session: String, onCloud: Bool, turnRunning: Bool, turnStartedAtMs: Double?, moving: Bool
    public init(id: String, session: String, onCloud: Bool, turnRunning: Bool, turnStartedAtMs: Double?, moving: Bool) {
        self.id = id; self.session = session; self.onCloud = onCloud; self.turnRunning = turnRunning
        self.turnStartedAtMs = turnStartedAtMs; self.moving = moving
    }
}

/// Where a move to Cloud lands.
public enum CloudPlaceMachine: Sendable { case reuse(String), create }

/// A Cloud machine as the own-VM rule reads it.
public struct CloudPlaceOwnMachine: Encodable, Sendable {
    public var id: String, sessions: [String], gone: Bool
    public init(id: String, sessions: [String], gone: Bool) { self.id = id; self.sessions = sessions; self.gone = gone }
}

/// What the app supplies: its chats, how it runs a move, and what its ledger knows. Everything else is here.
@MainActor
public protocol CloudPlaceHost: AnyObject {
    /// Every chat the app shows that may move: local ones, and Cloud ones a move from this Mac put there.
    func placeChats() -> [CloudPlaceChat]
    /// Runs the chat's move (to Cloud on `machine`, or back) as the app's move actions do, and returns when it ends.
    func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger) async
    /// The machine this session was moved to before, and the machines with the sessions each holds.
    func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine])
    /// Calls `handler` with the session of every turn that ends.
    func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void)
}

/// The chat place controls' runs and Auto: Swift draws and calls, Rust decides (`cloud_move_place_*`).
@MainActor
public final class CloudPlaceDriver {
    public let place: CloudPlaceFlows
    private let host: (any CloudPlaceHost)?  // the app's adapter holds services unowned: no cycle
    private var signals: CloudAutoSignals?
    /// The next re-read while an Auto chat exists; none is scheduled when no chat is on Auto.
    private let tick = DemandTimer(owner: "CloudPlaceDriver.tick")
    /// When each session's last turn ended (for the rule's idle time).
    private var turnEnded: [String: UInt64] = [:]

    /// How often Auto reads again with no change to wake it.
    static let interval: TimeInterval = 30

    public init(place: CloudPlaceFlows, host: any CloudPlaceHost) { self.place = place; self.host = host }

    private func chat(_ id: String) -> CloudPlaceChat? { host?.placeChats().first { $0.id == id } }

    // MARK: Actions

    /// `chatPlace.set`: records the mode, and moves the chat where it puts it now (Cloud: its own VM; Local: back).
    public func setMode(_ mode: String, tab: String) {
        guard ["local", "cloud", "auto"].contains(mode), let chat = chat(tab) else { return }
        place.setMode(mode, of: chat.session)
        switch mode {
        case "cloud" where !chat.onCloud: move(chat, toCloud: true, trigger: .person)
        case "local" where chat.onCloud: move(chat, toCloud: false, trigger: .person)
        case "auto": evaluate()
        default: break
        }
    }

    /// `chatMove.cancel`: the reducer decides whether the move stops (through `sync`) or finishes.
    public func cancel(tab: String?, session: String?) {
        guard let session = tab.flatMap(chat(_:))?.session ?? session else { return }
        place.cancel(session)
    }

    /// `chatMove.retry`: the chat's move again, as the person's.
    public func retry(tab: String) {
        guard let chat = chat(tab) else { return }
        run(chat, toCloud: !chat.onCloud, machine: nil, trigger: .person)
    }

    /// `cloudEvacuate`: every local chat (or the named ones) to its own VM, as many at once as Rust's plan says.
    public func evacuate(sessions named: [String]?) {
        struct Item: Encodable { var session: String, at: String, started: Bool, turnRunning: Bool, moving: Bool }
        struct Request: Encodable { var chats: [Item], selected: [String]? }
        struct Plan: Decodable { var moves: [String], parallel: Int }
        let all = host?.placeChats() ?? []
        let request = Request(chats: all.map { Item(session: $0.session, at: $0.onCloud ? "cloud" : "local", started: true, turnRunning: $0.turnRunning, moving: $0.moving) },
                              selected: named)
        guard let plan = CloudMoveCore().call("place_evacuate", request, as: Plan.self) else { return }
        let queue = plan.moves.compactMap { session in all.first { $0.session == session } }
        // task-owner: one-shot; ends when the last move ends.
        Task {
            var next = queue.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                func launch() -> Bool {
                    guard let chat = next.next() else { return false }
                    group.addTask { @MainActor in await self.moved(chat, toCloud: true, trigger: .evacuate) }
                    return true
                }
                for _ in 0..<max(1, plan.parallel) { if !launch() { break } }
                for await _ in group { _ = launch() }
            }
        }
    }

    // MARK: Running a move

    private func move(_ chat: CloudPlaceChat, toCloud: Bool, trigger: CloudPlaceFlows.Trigger) {
        // task-owner: one move; the app's registry tracks its work.
        Task { await moved(chat, toCloud: toCloud, trigger: trigger) }
    }

    private func run(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger) {
        // task-owner: one move; the app's registry tracks its work.
        Task { await host?.placeRun(chat, toCloud: toCloud, machine: machine, trigger: trigger) }
    }

    /// To Cloud, the chat's own VM (Rust's rule): the one it used before when still there and holding no other chat, else a new one.
    private func moved(_ chat: CloudPlaceChat, toCloud: Bool, trigger: CloudPlaceFlows.Trigger) async {
        await host?.placeRun(chat, toCloud: toCloud, machine: toCloud ? ownMachine(for: chat.session) : nil, trigger: trigger)
    }

    func ownMachine(for session: String) -> CloudPlaceMachine? {
        struct Request: Encodable { var session: String, before: String?, machines: [CloudPlaceOwnMachine] }
        struct Reply: Decodable {
            var action: String, machine: String?
            enum CodingKeys: String, CodingKey { case action = "do", machine }
        }
        guard let facts = host?.placeOwnFacts(session),
              let reply = CloudMoveCore().call("place_own_machine", Request(session: session, before: facts.before, machines: facts.machines), as: Reply.self) else { return nil }
        return reply.action == "reuse" ? reply.machine.map(CloudPlaceMachine.reuse) : .create
    }

    // MARK: Auto

    /// Starts watching: every change of a signal asks Rust about each Auto chat. Sleep and wake come in through ``slept(_:)``.
    public func start() {
        guard signals == nil else { return }
        let signals = CloudAutoSignals { [weak self] event in
            guard let self else { return }
            if case .turnEnded(let session) = event { turnEnded[session] = place.nowMs; return }
            evaluate()
        }
        self.signals = signals
        signals.start()
        host?.placeOnTurnEnded { session in signals.post(.turnEnded(session)) }
    }

    /// The system is about to sleep (true) or woke (false): told by the app's sleep/wake adapter.
    public func slept(_ asleep: Bool) { signals?.post(.asleep(asleep)) }

    /// Asks Rust what to do with each Auto chat now, and runs the moves it names.
    public func evaluate() {
        guard let signals, let host else { return }
        let autos = host.placeChats().filter { place.mode(of: $0.session) == "auto" }
        guard !autos.isEmpty else { tick.cancel(); return }
        tick.schedule(after: .seconds(Self.interval)) { @MainActor [weak self] in self?.evaluate() }
        let now = signals.signals()
        let nowMs = place.nowMs
        for chat in autos {
            // A move that failed or was cancelled waits for the person (Retry), never an Auto loop.
            if let state = place.state(of: chat.session), state == "failed" || state == "cancelled" { continue }
            let turnMs = chat.turnRunning ? chat.turnStartedAtMs.map { UInt64(max(0, Date().timeIntervalSince1970 * 1000 - $0)) } ?? 0 : 0
            let ended = turnEnded[chat.session]
            let ask = CloudAutoSignals.Chat(at: chat.onCloud ? "cloud" : "local", movedByAuto: place.autoMoved.contains(chat.session),
                                            turnRunning: chat.turnRunning, turnMs: turnMs, queued: 0,
                                            idleMs: chat.turnRunning ? 0 : ended.map { nowMs &- $0 } ?? now.idleMs ?? 0,
                                            moving: chat.moving || place.isMoving(chat.session))
            guard let answer = signals.decide(ask, signals: now) else { continue }
            switch answer.action {
            case "toCloud": move(chat, toCloud: true, trigger: .auto(answer.reason ?? "away"))
            case "back": move(chat, toCloud: false, trigger: .auto("back"))
            default: break
            }
        }
    }
}
