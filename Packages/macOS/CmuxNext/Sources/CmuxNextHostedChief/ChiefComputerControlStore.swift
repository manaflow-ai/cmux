public import CmuxNextHomeEngine
public import Foundation

/// Who drives a Chief's computer, in this app (Chief computer take-over, DESIGN "Control lease").
///
/// One owner per computer kind. For a user Cloud machine attached to a Chief on this Mac, this store
/// IS the lease: `cloud computer-control` (the App's `CloudHandlers.computerControlEffect`), the
/// profile's Computer tab and the Chief's `cloud_computer` tool all read and change it here, per
/// machine id, in memory (a relaunch starts every machine at `chief`). For a Cloud Chief's own sandbox
/// the Worker owns the lease; this store keeps the last answer of its routes
/// (``ChiefComputerControlClient``) so every view of that Chief reads one value.
///
/// Observers are held weakly by their token: dropping the token stops the calls.
@MainActor
public final class ChiefComputerControlStore {
    /// One computer: a Cloud machine by id, or a Cloud Chief's sandbox by its agent id.
    public enum Key: Hashable, Sendable {
        case machine(String)
        case agent(String)
    }

    /// What `cloud computer-control` asks.
    public enum Action: String, Sendable, CaseIterable {
        case status
        case takeOver = "take_over"
        case handBack = "hand_back"
        case requestHuman = "request_human"
    }

    /// A run the store refuses, with the words the caller hears.
    public enum Refusal: Error, Equatable {
        /// No machine, an id no Cloud machine has, or (for an ask) one this app does not list.
        case noMachine
        /// An action other than the four.
        case badAction
        /// A change from another client (a phone, another Mac): only this Mac changes the lease.
        case notHere
        /// Only the person's own gesture does this: a take-over, or giving back a computer the person
        /// took over (a Chief's `hand_back` ends only its own `request_human`). The message starts
        /// with the code `computer.user_origin_required`, which the Chief's tool reads.
        case userOriginRequired

        public var message: String {
            switch self {
            case .noMachine: String(localized: "cloud.computerControl.noMachine", defaultValue: "Name the Cloud machine whose computer it is (machine).", table: "HostedChief", bundle: .module)
            case .badAction: String(localized: "cloud.computerControl.badAction", defaultValue: "Say what to do: status, take_over, hand_back or request_human.", table: "HostedChief", bundle: .module)
            case .notHere: String(localized: "cloud.computerControl.notHere", defaultValue: "Who drives a Chief's computer changes only on this Mac.", table: "HostedChief", bundle: .module)
            case .userOriginRequired: "computer.user_origin_required: " + String(localized: "cloud.computerControl.userOriginRequired", defaultValue: "Only the person can take over this computer or give it back once they took it.", table: "HostedChief", bundle: .module)
            }
        }
    }

    /// The banner of the Chief's ask on machine `title`: its title, and the reason or the next step.
    public static func askText(machine title: String, reason: String?) -> (title: String, body: String) {
        (String(format: String(localized: "cloud.computerControl.askTitle", defaultValue: "Your Chief needs you on %@", table: "HostedChief", bundle: .module), title),
         reason ?? String(localized: "cloud.computerControl.askBody", defaultValue: "Take over its computer to continue.", table: "HostedChief", bundle: .module))
    }

    private struct Lease {
        var state: HomeChiefComputerControlState
        /// The person holds it because the Chief asked (``Action/requestHuman``), and has not taken
        /// it over themselves since.
        var askedByChief = false
    }

    private final class Observer {
        let onChange: @MainActor () -> Void
        init(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    }

    private struct WeakObserver {
        weak var observer: Observer?
    }

    private var leases: [Key: Lease] = [:]
    private var observers: [Key: [WeakObserver]] = [:]
    /// Whether the account may have a Chief computer, per agent, as the sandbox route last said.
    private var entitlement: [String: Bool] = [:]
    /// The status read in flight per agent (``refresh(agent:client:)``): one at a time.
    private var refreshing: [String: Task<Void, Never>] = [:]
    /// Now, in ms since 1970 (tests pass their own).
    public var now: () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    /// The Chief asked the person to take over machine `id` (posts the attention notice).
    public var onHumanRequested: ((_ machine: String, _ state: HomeChiefComputerControlState) -> Void)?
    /// The Chief's ask on machine `id` ended: the person took over or the computer went back to the
    /// Chief (withdraws that notice).
    public var onAskEnded: ((_ machine: String) -> Void)?

    public init() {}

    /// The machine id as the store keys it (the Cloud id as the machine list has it, trimmed), or nil
    /// for one no machine has (empty, too long, or with characters no Cloud machine id uses).
    public nonisolated static func machineKey(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// A reason as the lease keeps it: trimmed, at most 200 characters, nil when empty.
    public nonisolated static func trimmedReason(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }

    // MARK: Reads

    /// The lease of `key`; nil while a sandbox's is not known yet. A machine nobody changed reads `chief`.
    public func state(_ key: Key) -> HomeChiefComputerControlState? {
        if let lease = leases[key] { return lease.state }
        if case .machine = key { return .chief }
        return nil
    }

    /// Whether the account may have a computer for Chief `agent`; nil until the route said.
    public func entitled(agent: String) -> Bool? { entitlement[agent] }

    /// Calls `onChange` whenever `key`'s lease changes, while the returned token lives.
    public func observe(_ key: Key, _ onChange: @escaping @MainActor () -> Void) -> AnyObject {
        let observer = Observer(onChange)
        observers[key, default: []].removeAll { $0.observer == nil }
        observers[key, default: []].append(WeakObserver(observer: observer))
        return observer
    }

    // MARK: Machine leases (this store owns them)

    /// One `cloud computer-control` run from its raw arguments: the machine's key and its lease after.
    /// `fromAnotherClient`: a phone or another Mac asked (only `status` answers it, default deny).
    /// `knows`: whether this app lists the machine; an ask about one it does not posts nothing.
    public func run(machine raw: String?, action rawAction: String?, reason: String?, fromAnotherClient: Bool,
                    byPerson: Bool, knows: (String) -> Bool) throws(Refusal) -> (machine: String, state: HomeChiefComputerControlState) {
        guard let machine = raw.flatMap(Self.machineKey) else { throw .noMachine }
        guard let action = rawAction.flatMap(Action.init(rawValue:)) else { throw .badAction }
        if action != .status, fromAnotherClient { throw .notHere }
        if action == .requestHuman, !knows(machine) { throw .noMachine }
        return (machine, try perform(action, machine: machine, reason: reason, byPerson: byPerson))
    }

    /// Runs `action` on machine `machine` (a ``machineKey(_:)``) and answers its lease after.
    /// `byPerson`: the person's own gesture in this app (the profile's buttons, the palette).
    @discardableResult
    public func perform(_ action: Action, machine: String, reason: String? = nil, byPerson: Bool) throws(Refusal) -> HomeChiefComputerControlState {
        let key = Key.machine(machine)
        let before = leases[key] ?? Lease(state: .chief)
        var lease = before
        switch action {
        case .status:
            return lease.state
        case .takeOver:
            guard byPerson else { throw .userOriginRequired }
            // A take-over while the Chief's ask stands keeps its since_ms: the person already holds it.
            if lease.state.holder != .human { lease.state = HomeChiefComputerControlState(holder: .human, sinceMs: now()) }
            lease.askedByChief = false
            lease.state.reason = nil
        case .handBack:
            guard lease.state.holder == .human else { return lease.state }
            guard byPerson || lease.askedByChief else { throw .userOriginRequired }
            lease = Lease(state: HomeChiefComputerControlState(holder: .chief, sinceMs: now()))
        case .requestHuman:
            let reason = Self.trimmedReason(reason)
            if lease.state.holder == .human {
                // The person drives already: a Chief's later ask only updates the reason of its own ask.
                guard lease.askedByChief else { return lease.state }
                lease.state.reason = reason
            } else {
                lease = Lease(state: HomeChiefComputerControlState(holder: .human, sinceMs: now(), reason: reason), askedByChief: true)
            }
        }
        leases[key] = lease
        if lease.askedByChief, !before.askedByChief { onHumanRequested?(machine, lease.state) }
        if before.askedByChief, !lease.askedByChief { onAskEnded?(machine) }
        if lease.state != before.state { notify(key) }
        return lease.state
    }

    // MARK: Sandbox leases (the Worker owns them)

    /// The Worker's answer for Chief `agent`'s sandbox: its lease and, from the status route, whether
    /// the account may have a computer.
    public func apply(agent: String, state: HomeChiefComputerControlState?, entitled: Bool?) {
        if let entitled { entitlement[agent] = entitled }
        guard let state else { return }
        let key = Key.agent(agent)
        // The Worker's since_ms only grows: an older answer (a status read that left before a
        // take-over's reply came back) never overwrites a newer lease. 0 is a lease the Worker reset
        // (a new sandbox), which always lands.
        if let known = leases[key]?.state, known == state || (state.sinceMs != 0 && state.sinceMs < known.sinceMs) { return }
        leases[key] = Lease(state: state)
        notify(key)
    }

    /// Reads Chief `agent`'s sandbox lease through the status route; a read already in flight answers
    /// for this one too. A failed read keeps the last lease.
    public func refresh(agent: String, client: ChiefComputerControlClient) {
        guard refreshing[agent] == nil else { return }
        // task-owner: one status read per agent, in `refreshing` until it answers
        refreshing[agent] = Task { [weak self] in
            let snapshot = try? await client.status(agent: agent)
            guard let self else { return }
            self.refreshing[agent] = nil
            if let snapshot { self.apply(agent: agent, state: snapshot.control, entitled: snapshot.entitled) }
        }
    }

    /// The status read in flight for `agent` (tests wait on it).
    public func refreshTask(agent: String) -> Task<Void, Never>? { refreshing[agent] }

    /// The status route's reply `body` for Chief `agent`, read by another caller (the profile's
    /// Computer tab reads it on its own cadence): its lease lands here with no request of its own.
    public func ingest(agent: String, statusBody body: Data) {
        guard let snapshot = ChiefComputerControlClient.statusSnapshot(body) else { return }
        apply(agent: agent, state: snapshot.control, entitled: snapshot.entitled)
    }

    private func notify(_ key: Key) {
        let live = (observers[key] ?? []).compactMap(\.observer)
        observers[key] = live.map { WeakObserver(observer: $0) }
        for observer in live { observer.onChange() }
    }
}
