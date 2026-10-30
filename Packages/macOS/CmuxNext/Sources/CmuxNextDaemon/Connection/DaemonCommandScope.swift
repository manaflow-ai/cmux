import CryptoKit
public import Foundation
import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
/// With a ``cause`` the scope records each `mutation_id` and client
/// `transaction` it sends in the connection's ``MutationCauseLedger``, so the
/// echo applies in that cause: ``person(clock:lifespan:)`` for a person's
/// action run, ``automation(idempotencyKey:)`` for the control socket's. A
/// person scope is never closed, so its credit ends with its lifespan.
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

    private struct State {
        var open: Set<UInt64> = []
        var nextTicket: UInt64 = 0
        var mutations = 0
        var derived: [String: Int] = [:]
        var failures: [Failure] = []
        var created: [DaemonCreatedObject] = []
        var barriers: [String: UInt64] = [:]
        var closed = false
        var idleWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
        /// What the run did and when (`stageLog`): the first 16 entries and
        /// the last 32 (`appendKeepingHead`).
        var stages: [String] = []
    }

    public let idempotencyKey: String?
    /// The cause the echoes of this scope's mutations apply in, or nil to
    /// leave them to the daemon's envelope cause.
    public let cause: ObservationCause?
    /// False for a person's run: nothing waits for its commands, so it opens
    /// no tickets and records no barriers or created objects.
    private let tracksCommands: Bool
    /// Whether a mutation sent now still gets ``cause``: past a person
    /// scope's lifespan it does not.
    private let credits: @Sendable () -> Bool
    private let state = Mutex(State())

    /// How long after a person's input the commands of its run apply as
    /// `person` (p06-scheduler.md, "Person cause, app side": 2 s).
    public static let personLifespan: Duration = .seconds(2)

    public convenience init(idempotencyKey: String? = nil) {
        self.init(idempotencyKey: idempotencyKey, cause: nil, tracksCommands: true, credits: { true })
    }

    private init(idempotencyKey: String?, cause: ObservationCause?, tracksCommands: Bool, credits: @escaping @Sendable () -> Bool) {
        self.idempotencyKey = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }
        self.cause = cause
        self.tracksCommands = tracksCommands
        self.credits = credits
    }

    /// The scope of a person's action run (a key, a click, the palette): the
    /// echoes of what it sends within `lifespan` of opening apply as `person`;
    /// a task it started that sends later sends ordinary commands. Chrome
    /// bounds a gesture's credit the same way: transient user activation
    /// expires a fixed span after the input
    /// (third_party/blink/common/frame/user_activation_state.cc,
    /// `kActivationLifespan`). It tracks no commands; nothing waits for it.
    ///
    /// - Parameters:
    ///   - clock: The clock the lifespan runs on (a test clock moves only when the test says).
    ///   - lifespan: How long after opening a sent mutation is the person's.
    public static func person<C: Clock>(clock: C, lifespan: Duration = personLifespan) -> DaemonCommandScope
        where C.Duration == Duration {
        let opened = clock.now
        return DaemonCommandScope(idempotencyKey: nil, cause: .person, tracksCommands: false,
                                  credits: { opened.duration(to: clock.now) < lifespan })
    }

    /// ``person(clock:lifespan:)`` on the continuous clock.
    public static func person() -> DaemonCommandScope {
        person(clock: ContinuousClock())
    }

    /// The scope of a control-socket action run (the CLI, MCP, a script, an
    /// agent): its echoes apply as `automation` until it is closed.
    public static func automation(idempotencyKey: String?) -> DaemonCommandScope {
        DaemonCommandScope(idempotencyKey: idempotencyKey, cause: .automation, tracksCommands: true, credits: { true })
    }

    // MARK: - Stage log

    private let createdAt = ContinuousClock.now

    /// What this run did and when, as `stage@ms` from the scope's creation:
    /// its stages (`note`, `stage`), each command ticket opened (`open#N`)
    /// and closed (`close#N label`). A control timeout reports it as
    /// `data.waiting_on`, so a timed-out `action.run` says what it waited on.
    public var stageLog: [String] {
        state.withLock { state in
            state.stages + (state.open.isEmpty ? [] : ["open now: " + state.open.sorted().map { "#\($0)" }.joined(separator: " ")])
        }
    }

    /// Records `stage` in the stage log.
    public func note(_ stage: String) {
        let entry = stamped(stage)
        state.withLock { state in
            state.stages.appendKeepingHead(entry)
        }
    }

    private func stamped(_ stage: String) -> String {
        let ms = (ContinuousClock.now - createdAt).components
        return "\(stage)@\(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000)"
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
        guard tracksCommands else { return nil }
        return state.withLock { state -> Ticket? in
            guard !state.closed else { return nil }
            state.nextTicket &+= 1
            state.open.insert(state.nextTicket)
            return Ticket(id: state.nextTicket)
        }.map { ticket in
            note("open#\(ticket.id)" + (label.map { " " + $0 } ?? ""))
            return ticket
        }
    }

    /// Closes `ticket`, recording `failure` when the command failed.
    public func end(_ ticket: Ticket?, failure: Failure? = nil, label: String? = nil) {
        guard let ticket else { return }
        let entry = stamped("close#\(ticket.id)" + (label.map { " " + $0 } ?? ""))
        let waiters = state.withLock { state -> [OnceContinuation<Void, OnceContinuationError>] in
            guard state.open.remove(ticket.id) != nil else { return [] }
            state.stages.appendKeepingHead(entry)
            if let failure { state.failures.append(failure) }
            guard state.open.isEmpty else { return [] }
            defer { state.idleWaiters.removeAll() }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    /// Records that `machine`'s events up to `sequence` cover a command's echo.
    public func noteBarrier(_ sequence: UInt64, machine: String) {
        guard tracksCommands else { return }
        state.withLock { state in
            guard !state.closed else { return }
            state.barriers[machine] = max(state.barriers[machine] ?? 0, sequence)
        }
    }

    /// Records objects a creating command made (`DaemonCreatingRequest`).
    public func noteCreated(_ objects: [DaemonCreatedObject]) {
        guard tracksCommands, !objects.isEmpty else { return }
        state.withLock { state in
            guard !state.closed else { return }
            for object in objects where !state.created.contains(object) { state.created.append(object) }
        }
    }

    /// True while no ticket is open.
    public var isIdle: Bool { state.withLock { $0.open.isEmpty } }

    /// Returns once no ticket is open (at once when none is). A caller that
    /// must know no command follows re-checks ``isIdle`` on the actor the
    /// commands start from, because a task may open its next ticket right
    /// after closing one. A waiter dropped unresumed returns too: the caller re-checks either way.
    public func waitUntilIdle() async {
        _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            let idle = state.withLock { state -> Bool in
                if state.open.isEmpty { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume(returning: ()) }
        }
    }

    /// Stops deriving ids and recording; later commands are ordinary.
    public func close() {
        state.withLock { $0.closed = true }
    }

    /// False once the action answered (``close()``): nobody reads what a later command records.
    public var isOpen: Bool { state.withLock { !$0.closed } }
    /// True while this scope answers its commands' failures to a caller: an open scope that tracks commands (the control
    /// socket's `action.run`, ``automation(idempotencyKey:)``). A person scope (``person(clock:lifespan:)``) never
    /// closes and answers nobody, so a failure in a person's run is shown where it happens.
    public var answersFailures: Bool { tracksCommands && isOpen }
    public var failures: [Failure] { state.withLock { $0.failures } }
    public var created: [DaemonCreatedObject] { state.withLock { $0.created } }
    public var ticketCount: UInt64 { state.withLock { $0.nextTicket } }

    /// The event sequence of `machine` that covers every command's echo, or
    /// nil when no command reported one.
    public func barrier(machine: String) -> UInt64? { state.withLock { $0.barriers[machine] } }

    /// Every machine's barrier, by machine id.
    public var barriers: [String: UInt64] { state.withLock { $0.barriers } }

    // MARK: - Idempotency

    /// The next `mutation_id` for this action: derived from the idempotency
    /// key and the mutation's ordinal, or nil (a fresh id) without a key or
    /// once closed.
    public func nextMutationID() -> String? {
        guard let key = idempotencyKey else { return nil }
        let ordinal = state.withLock { state -> Int? in
            guard !state.closed else { return nil }
            state.mutations += 1
            return state.mutations
        }
        return ordinal.map { Self.derivedUUID(key: key, kind: "mutation", ordinal: $0).uuidString.lowercased() }
    }

    /// Records that this scope sent `mutationID`, with its ``cause``, in
    /// `ledger` (the sending connection's). Nothing without a cause, once
    /// closed, or past a person scope's lifespan.
    public func recordMutation(_ mutationID: String, in ledger: MutationCauseLedger) {
        guard let cause = creditedCause else { return }
        ledger.record(mutationID, cause: cause)
    }

    /// Records that this scope sent a request carrying `transaction`, like
    /// ``recordMutation(_:in:)``.
    public func recordTransaction(_ transaction: ClientTransactionID, in ledger: MutationCauseLedger) {
        guard let cause = creditedCause else { return }
        ledger.record(transaction: transaction, cause: cause)
    }

    /// ``cause`` while this scope still credits what it sends.
    private var creditedCause: ObservationCause? {
        guard let cause, credits(), !state.withLock({ $0.closed }) else { return nil }
        return cause
    }

    /// The next generated id of `kind` (a new workspace key, a reserved
    /// terminal id) for this action, derived like ``nextMutationID()``.
    public func nextDerivedUUID(_ kind: String) -> UUID? {
        guard let key = idempotencyKey else { return nil }
        let ordinal = state.withLock { state -> Int? in
            guard !state.closed else { return nil }
            state.derived[kind, default: 0] += 1
            return state.derived[kind, default: 0]
        }
        return ordinal.map { Self.derivedUUID(key: key, kind: kind, ordinal: $0) }
    }

    /// A UUID from SHA-256 of key, kind and ordinal, in the version 4
    /// layout: the hash bits stand in for the random bits, and cmux-tui
    /// accepts caller-chosen terminal ids only as UUIDv4.
    static func derivedUUID(key: String, kind: String, ordinal: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("cmux-next/\(kind)/\(ordinal)/\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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
        guard let scope = current, scope.tracksCommands, let creating = request as? any DaemonCreatingRequest else { return }
        scope.noteCreated(creating.createdObjects(inAny: response))
    }
}

extension [String] {
    /// Appends `entry`, keeping the first 16 entries and the newest 32 (the
    /// end of a long run is what a timeout waited on).
    fileprivate mutating func appendKeepingHead(_ entry: String) {
        if count >= 48 { remove(at: 16) }
        append(entry)
    }
}
