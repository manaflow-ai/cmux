import CryptoKit
public import Foundation
import Synchronization

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
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    public let idempotencyKey: String?
    private let state = Mutex(State())

    public init(idempotencyKey: String? = nil) {
        self.idempotencyKey = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Tickets

    /// Opens a ticket for a command about to be sent, or nil once closed.
    public func begin() -> Ticket? {
        state.withLock { state -> Ticket? in
            guard !state.closed else { return nil }
            state.nextTicket &+= 1
            state.open.insert(state.nextTicket)
            return Ticket(id: state.nextTicket)
        }
    }

    /// Closes `ticket`, recording `failure` when the command failed.
    public func end(_ ticket: Ticket?, failure: Failure? = nil) {
        guard let ticket else { return }
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.open.remove(ticket.id) != nil else { return [] }
            if let failure { state.failures.append(failure) }
            guard state.open.isEmpty else { return [] }
            defer { state.idleWaiters.removeAll() }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Records that `machine`'s events up to `sequence` cover a command's echo.
    public func noteBarrier(_ sequence: UInt64, machine: String) {
        state.withLock { state in
            guard !state.closed else { return }
            state.barriers[machine] = max(state.barriers[machine] ?? 0, sequence)
        }
    }

    /// Records objects a creating command made (`DaemonCreatingRequest`).
    public func noteCreated(_ objects: [DaemonCreatedObject]) {
        guard !objects.isEmpty else { return }
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
    /// after closing one.
    public func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.open.isEmpty { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Stops deriving ids and recording; later commands are ordinary.
    public func close() {
        state.withLock { $0.closed = true }
    }

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

    /// The next generated id of `kind` (a new workspace key, a reserved
    /// terminal id) for this action, derived like ``nextMutationID()``.
    public func nextDerivedUUID(_ kind: String) -> UUID? {
        guard let key = idempotencyKey else { return nil }
        let ordinal = state.withLock { state -> Int? in
            guard !state.closed else { return nil }
            state.derived[kind, default: 0] += 1
            return state.derived[kind]
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
        guard let scope = current, let creating = request as? any DaemonCreatingRequest else { return }
        scope.noteCreated(creating.createdObjects(inAny: response))
    }
}
