internal import CCmuxDaemonConnFFI
public import Foundation
import CmuxNextCompat

/// Everything one app action sent to its daemons (plans/cmux-next/state-ownership.md 4).
///
/// The control socket binds a scope as ``current`` (a task local) while an
/// action's handler runs, so every task the handler starts inherits it.
/// Each command funnel (`DaemonService.run`, `perform`, `commit`, `send`)
/// opens a ticket on entry and closes it after the reply, recording a
/// failure and the event sequence that covers the command's echo; the
/// connection records the objects a creating command made. `action.run`
/// then waits until no ticket is open and answers with what the scope saw.
///
/// With an idempotency key, the mutation ids and generated keys the action
/// sends derive from the key and the command's ordinal, so a retry with the
/// same key replays in the daemon instead of applying twice. A closed scope
/// derives nothing and records nothing: a task that outlives the action
/// sends ordinary commands.
///
/// The bookkeeping is Rust's (`cmux_daemon_scope_*`, cmux-daemon-conn-core src/scope.rs); the task local,
/// the idle waiters and the types stay here.
public final class DaemonCommandScope: Sendable {
    /// The scope of the action whose handler (or a task it started) is running.
    @TaskLocal public static var current: DaemonCommandScope?

    /// The machine id of the local daemon, whose events the control
    /// snapshot's `daemonSequence` counts.
    public static let localMachine = "local"

    /// A command that failed. `mayHaveApplied` is true when the reply
    /// missed its deadline: the daemon may still apply it.
    public struct Failure: Sendable, Hashable {
        public var label: String
        public var message: String
        public var mayHaveApplied: Bool
        public var terminalMayAppear: Bool

        public init(label: String, message: String, mayHaveApplied: Bool = false, terminalMayAppear: Bool = false) {
            self.label = label
            self.message = message
            self.mayHaveApplied = mayHaveApplied
            self.terminalMayAppear = terminalMayAppear
        }
    }

    /// An open command. Close it exactly once with ``end(_:failure:)``.
    public struct Ticket: Sendable {
        let id: UInt64
    }

    /// The Rust scope and the idle waiters, under one lock: an `end` that makes the scope idle and a
    /// `waitUntilIdle` that finds it busy never miss each other.
    private struct State: ~Copyable {
        let scope: OpaquePointer?
        var idleWaiters: [CheckedContinuation<Void, Never>] = []

        deinit { cmux_daemon_scope_free(scope) }

        func call(_ op: String, _ request: [String: Any] = [:]) -> [String: Any] {
            scope.flatMap { DaemonConnRules.call($0, op, request) } ?? [:]
        }
    }

    public let idempotencyKey: String?
    private let state: Mutex<State>

    public init(idempotencyKey: String? = nil) {
        let key = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }
        self.idempotencyKey = key
        let bytes = Array((key ?? "").utf8)
        state = Mutex(State(scope: bytes.withUnsafeBufferPointer { cmux_daemon_scope_new($0.baseAddress, $0.count) }))
    }

    // MARK: - Stage log

    private let createdAt = ContinuousClock.now

    /// Milliseconds since the scope's creation, the stage log's `@ms`.
    private var elapsedMilliseconds: UInt64 {
        let elapsed = (ContinuousClock.now - createdAt).components
        return UInt64(clamping: elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// What this run did and when, as `stage@ms` from the scope's creation:
    /// its stages (`note`, `stage`), each command ticket opened (`open#N`)
    /// and closed (`close#N label`). A control timeout reports it as
    /// `data.waiting_on`, so a timed-out `action.run` says what it waited on.
    public var stageLog: [String] {
        state.withLock { $0.call("stage_log")["log"] as? [String] ?? [] }
    }

    /// Records `stage` in the stage log.
    public func note(_ stage: String) {
        let at = elapsedMilliseconds
        state.withLock { _ = $0.call("note", ["stage": stage, "at_ms": at]) }
    }

    /// `note(stage)`, then true (for a `guard` condition).
    public func noting(_ stage: String) -> Bool {
        note(stage)
        return true
    }

    /// Runs `body` between the stage log entries `name` and `name done`.
    public func stage<T>(_ name: String, _ body: () async -> T) async -> T {
        note(name)
        let value = await body()
        note(name + " done")
        return value
    }

    /// The barriers, noting the snapshot stage that waits for them.
    public func snapshotBarriers() -> [String: UInt64] {
        note("snapshot")
        return barriers
    }

    // MARK: - Tickets

    /// Opens a ticket for a command about to be sent, or nil once closed.
    public func begin(label: String? = nil) -> Ticket? {
        let at = elapsedMilliseconds
        let reply = state.withLock { $0.call("begin", ["label": label ?? NSNull(), "at_ms": at]) }
        return (reply["ticket"] as? NSNumber).map { Ticket(id: $0.uint64Value) }
    }

    /// Closes `ticket`, recording `failure` when the command failed.
    public func end(_ ticket: Ticket?, failure: Failure? = nil, label: String? = nil) {
        guard let ticket else { return }
        let at = elapsedMilliseconds
        let request: [String: Any] = ["ticket": ticket.id, "failure": failure.map(\.json) ?? NSNull(),
                                      "label": label ?? NSNull(), "at_ms": at]
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.call("end", request)["became_idle"] as? Bool == true else { return [] }
            defer { state.idleWaiters.removeAll() }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Records that `machine`'s events up to `sequence` cover a command's echo.
    public func noteBarrier(_ sequence: UInt64, machine: String) {
        state.withLock { _ = $0.call("note_barrier", ["sequence": sequence, "machine": machine]) }
    }

    /// Records objects a creating command made (`DaemonCreatingRequest`).
    public func noteCreated(_ objects: [DaemonCreatedObject]) {
        guard !objects.isEmpty else { return }
        let request: [String: Any] = ["objects": objects.map { ["kind": $0.kind.rawValue, "id": $0.id] }]
        state.withLock { _ = $0.call("note_created", request) }
    }

    /// What the Rust scope holds (`state`).
    private var snapshot: [String: Any] { state.withLock { $0.call("state") } }

    /// True while no ticket is open.
    public var isIdle: Bool { snapshot["idle"] as? Bool ?? true }

    /// Returns once no ticket is open (at once when none is). A caller that
    /// must know no command follows re-checks ``isIdle`` on the actor the
    /// commands start from, because a task may open its next ticket right
    /// after closing one.
    public func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.call("state")["idle"] as? Bool ?? true { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Stops deriving ids and recording; later commands are ordinary.
    public func close() {
        state.withLock { _ = $0.call("close") }
    }

    /// False once the action answered (``close()``): nobody reads what a later command records.
    public var isOpen: Bool { snapshot["open"] as? Bool ?? false }
    public var failures: [Failure] { (snapshot["failures"] as? [[String: Any]] ?? []).map(Failure.init(json:)) }
    public var created: [DaemonCreatedObject] {
        (snapshot["created"] as? [[String: Any]] ?? []).compactMap { object in
            guard let kind = (object["kind"] as? String).flatMap(DaemonCreatedObject.Kind.init(rawValue:)),
                  let id = object["id"] as? String else { return nil }
            return DaemonCreatedObject(kind, id)
        }
    }
    public var ticketCount: UInt64 { (snapshot["ticket_count"] as? NSNumber)?.uint64Value ?? 0 }

    /// The event sequence of `machine` that covers every command's echo, or
    /// nil when no command reported one.
    public func barrier(machine: String) -> UInt64? { barriers[machine] }

    /// Every machine's barrier, by machine id.
    public var barriers: [String: UInt64] {
        (snapshot["barriers"] as? [String: NSNumber] ?? [:]).mapValues(\.uint64Value)
    }

    // MARK: - Idempotency

    /// The next `mutation_id` for this action: derived from the idempotency
    /// key and the mutation's ordinal, or nil (a fresh id) without a key or
    /// once closed.
    public func nextMutationID() -> String? {
        guard idempotencyKey != nil else { return nil }
        return state.withLock { $0.call("next_mutation_id")["id"] as? String }
    }

    /// The next generated id of `kind` (a new workspace key, a reserved
    /// terminal id) for this action, derived like ``nextMutationID()``: a UUID
    /// from SHA-256 of key, kind and ordinal in the version 4 layout
    /// (cmux-tui accepts caller-chosen terminal ids only as UUIDv4).
    public func nextDerivedUUID(_ kind: String) -> UUID? {
        guard idempotencyKey != nil else { return nil }
        return state.withLock { $0.call("next_derived", ["kind": kind])["uuid"] as? String }.flatMap(UUID.init(uuidString:))
    }
}

extension DaemonCommandScope.Failure {
    /// The Rust scope's form (`scope::Failure`).
    var json: [String: Any] {
        ["label": label, "message": message, "may_have_applied": mayHaveApplied, "terminal_may_appear": terminalMayAppear]
    }

    init(json: [String: Any]) {
        self.init(label: json["label"] as? String ?? "", message: json["message"] as? String ?? "",
                  mayHaveApplied: json["may_have_applied"] as? Bool ?? false,
                  terminalMayAppear: json["terminal_may_appear"] as? Bool ?? false)
    }
}

/// An object a daemon command created, as the daemon reported it. The
/// control socket maps it to a public id once the store has applied the echo.
public struct DaemonCreatedObject: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case workspace
        case screen
        case pane
        case tab
        case terminal
        case tabGroup = "tab-group"
        case workspaceGroup = "workspace-group"
    }

    public var kind: Kind
    /// Workspace key, handle (screen, pane, tab surface), terminal id, or group id.
    public var id: String

    public init(_ kind: Kind, _ id: String) {
        self.kind = kind
        self.id = id
    }
}

/// A command that creates objects. `DaemonConnection.request` reports
/// them to the current ``DaemonCommandScope``.
public protocol DaemonCreatingRequest: DaemonRequest {
    func createdObjects(in response: Response) -> [DaemonCreatedObject]
}

extension DaemonCreatingRequest {
    func createdObjects(inAny response: Any) -> [DaemonCreatedObject] {
        (response as? Response).map(createdObjects(in:)) ?? []
    }
}

extension DaemonCommandScope {
    /// Reports what `request` created, when it is a creating request, to
    /// the ``current`` scope.
    static func noteCreated(by request: some DaemonRequest, response: Any) {
        guard let scope = current, let creating = request as? any DaemonCreatingRequest else { return }
        scope.noteCreated(creating.createdObjects(inAny: response))
    }
}
