import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Observation

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
        public var queued = 0
        public var hasDraft = false
        public var branch: String?
        public var dirtyFiles = 0

        var json: [String: Any] {
            var cargo: [String: Any] = ["turnRunning": turnRunning, "continuesTurn": continuesTurn, "queued": queued, "hasDraft": hasDraft, "dirtyFiles": dirtyFiles]
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

    /// Each session's flow, as the reducer last returned it.
    @ObservationIgnored private var flows: [String: Data] = [:]
    /// What stops each session's running move (its Task), set by the action that runs it.
    @ObservationIgnored private var stoppers: [String: () -> Void] = [:]
    /// Sessions whose move Cancel stopped: the stop is no failure and offers no Retry.
    @ObservationIgnored private var cancelled: Set<String> = []
    /// Sessions Auto moved to Cloud (so Auto may bring them back; a person's Cloud stays), kept across launches.
    @ObservationIgnored public private(set) var autoMoved: Set<String> = []
    /// Each running move's trigger and direction, to record who moved it once it landed.
    @ObservationIgnored private var started: [String: (auto: Bool, toCloud: Bool)] = [:]
    @ObservationIgnored private let core: Core
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let modesKey: String
    @ObservationIgnored private let clock: @Sendable () -> UInt64

    public init(defaults: UserDefaults = .standard, key: String = "cmux.cloud.placeModes", core: Core? = nil, clock: (@Sendable () -> UInt64)? = nil) {
        self.defaults = defaults
        modesKey = key
        self.core = core ?? { operation, request in CloudStartCore().callData(operation, request) }
        self.clock = clock ?? { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
        if let kept = defaults.stringArray(forKey: key + ".autoMoved") { autoMoved = Set(kept) }
        if let data = defaults.data(forKey: key), let kept = try? JSONDecoder().decode([String: String].self, from: data) { modes = kept }
    }

    /// This computer's own name, as the move names the place it leaves or reaches.
    public nonisolated static var thisMac: String { MacName().hostName() }

    /// Milliseconds on the monotonic clock every event of a flow is stamped with.
    public var nowMs: UInt64 { clock() }

    // MARK: Modes

    public func mode(of session: String) -> String { modes[session] ?? "local" }

    public func setMode(_ mode: String, of session: String) {
        guard ["local", "cloud", "auto"].contains(mode), modes[session] != mode else { return }
        modes[session] = mode
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: modesKey) }
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
        if case .auto = trigger { started[session] = (true, toCloud) } else { started[session] = (false, toCloud) }
        return report(session, ["event": "begin", "session": session, "direction": toCloud ? "toCloud" : "toLocal", "trigger": trigger.json,
                                "from": from, "to": to, "cargo": cargo.json, "atMs": nowMs])
    }

    /// `step` starts (the steps before it are done).
    @discardableResult
    public func step(_ session: String?, _ step: String) -> Next { session.map { report(session, ["event": "step", "step": step, "atMs": nowMs]) } ?? .go }

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
        }
        return report(session, ["event": "live", "atMs": nowMs])
    }

    @discardableResult
    public func failed(_ session: String?, reason: String) -> Next {
        guard let session else { return .go }
        started[session] = nil
        return report(session, ["event": "failed", "reason": reason, "atMs": nowMs])
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

    /// The move's work ended (any way): its stopper goes.
    public func finished(_ session: String?) {
        guard let session else { return }
        stoppers[session] = nil
        started[session] = nil
        cancelled.remove(session)
    }

    /// Whether a flow of `session` is moving now (the reducer's own state, read from the kept view).
    public func isMoving(_ session: String) -> Bool { state(of: session) == "moving" }

    /// The session's view state (`moving`, `live`, `failed`, `cancelled`), nil with no flow.
    public func state(of session: String) -> String? {
        guard let data = views[session], let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["state"] as? String
    }

    /// Drops the session's flow and view (a Live move's card goes once the chat shows it).
    public func clear(_ session: String) {
        flows[session] = nil
        views[session] = nil
    }

    private func report(_ session: String, _ event: [String: Any]) -> Next {
        var request: [String: Any] = ["event": event]
        if let flow = flows[session], let object = try? JSONSerialization.jsonObject(with: flow) { request["flow"] = object }
        guard let body = try? JSONSerialization.data(withJSONObject: request), let reply = core("cloud_move_place_reduce", body),
              let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], let flow = answer["flow"],
              let kept = try? JSONSerialization.data(withJSONObject: flow) else { return .go }
        flows[session] = kept
        let nowMs = nowMs
        if let viewRequest = try? JSONSerialization.data(withJSONObject: ["flow": flow, "nowMs": nowMs] as [String: Any]),
           let view = core("cloud_move_place_view", viewRequest) {
            views[session] = view
        }
        return (answer["next"] as? String).flatMap(Next.init(rawValue:)) ?? .go
    }

    // MARK: The chat's place, for pane.tabState

    /// `place: {mode, at, cloudName?, move?}` for the chat header, as JSON; nil with no session.
    public func placeJSON(session: String?, onCloud: Bool, cloudName: String?) -> Data? {
        guard let session else { return nil }
        var place: [String: Any] = ["mode": mode(of: session), "at": onCloud ? "cloud" : "local"]
        if let cloudName { place["cloudName"] = cloudName }
        if let view = views[session], let move = try? JSONSerialization.jsonObject(with: view) { place["move"] = move }
        return try? JSONSerialization.data(withJSONObject: place, options: [.sortedKeys])
    }
}
