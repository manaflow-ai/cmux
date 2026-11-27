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

    public let idempotencyKey: String?
    // crash-allow: an immutable pointer to a Rust scope that locks its own Mutex on every call (ffi.rs cmux_daemon_scope_call)
    private struct Handle: @unchecked Sendable {
        let raw: OpaquePointer
    }

    private let handle: Handle?
    /// Held across a Rust call only where the idle check and the waiters must agree.
    private let idleWaiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let createdAt = ContinuousClock.now

    public init(idempotencyKey: String? = nil) {
        let key = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }
        self.idempotencyKey = key
        handle = Array((key ?? "").utf8).withUnsafeBufferPointer { cmux_daemon_scope_new($0.baseAddress, $0.count) }
            .map(Handle.init(raw:))
    }

    deinit {
        if let handle { cmux_daemon_scope_free(handle.raw) }
    }

    private func call(_ op: String, _ request: [String: Any] = [:]) -> [String: Any] {
        Self.call(op, encoded(request), on: handle)
    }

    /// `at_ms` stamps the stage log.
    private func encoded(_ request: [String: Any]) -> Data {
        let ms = (ContinuousClock.now - createdAt).components
        var request = request
        request["at_ms"] = ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000
        return (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
    }

    /// The Rust scope's reply to `op`, or empty.
    private static func call(_ op: String, _ data: Data, on handle: Handle?) -> [String: Any] {
        guard let handle = handle?.raw else { return [:] }
        var out = CmuxDaemonConnBytes(ptr: nil, len: 0)
        let code: Int32 = data.withUnsafeBytes { raw in
            op.withCString { name in
                cmux_daemon_scope_call(handle, name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
            }
        }
        defer { cmux_daemon_conn_bytes_free(out) }
        guard code == 0, let bytes = out.ptr, out.len > 0 else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: out.len))) as? [String: Any] ?? [:]
    }

    private func field(_ name: String) -> Any? { call("state")[name] }

    // MARK: - Stage log

    /// What this run did and when, as `stage@ms` from the scope's creation:
    /// its stages (`note`, `stage`), each command ticket opened (`open#N`)
    /// and closed (`close#N label`). A control timeout reports it as
    /// `data.waiting_on`, so a timed-out `action.run` says what it waited on.
    public var stageLog: [String] { call("stage_log")["log"] as? [String] ?? [] }

    /// Records `stage` in the stage log.
    public func note(_ stage: String) {
        _ = call("note", ["stage": stage])
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
        (call("begin", label.map { ["label": $0] } ?? [:])["ticket"] as? NSNumber).map { Ticket(id: $0.uint64Value) }
    }

    /// Closes `ticket`, recording `failure` when the command failed.
    public func end(_ ticket: Ticket?, failure: Failure? = nil, label: String? = nil) {
        guard let ticket else { return }
        var request: [String: Any] = ["ticket": ticket.id]
        if let label { request["label"] = label }
        if let failure {
            request["failure"] = [
                "label": failure.label, "message": failure.message,
                "may_have_applied": failure.mayHaveApplied, "terminal_may_appear": failure.terminalMayAppear,
            ]
        }
        let data = encoded(request)
        let handle = handle
        let waiters = idleWaiters.withLock { waiters -> [CheckedContinuation<Void, Never>] in
            guard Self.call("end", data, on: handle)["became_idle"] as? Bool == true else { return [] }
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Records that `machine`'s events up to `sequence` cover a command's echo.
    public func noteBarrier(_ sequence: UInt64, machine: String) {
        _ = call("note_barrier", ["sequence": sequence, "machine": machine])
    }

    /// Records objects a creating command made (`DaemonCreatingRequest`).
    public func noteCreated(_ objects: [DaemonCreatedObject]) {
        _ = call("note_created", ["objects": objects.map { ["kind": $0.kind.rawValue, "id": $0.id] }])
    }

    /// True while no ticket is open.
    public var isIdle: Bool { field("idle") as? Bool ?? true }

    /// Returns once no ticket is open (at once when none is). A caller that
    /// must know no command follows re-checks ``isIdle`` on the actor the
    /// commands start from, because a task may open its next ticket right
    /// after closing one.
    public func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let data = encoded([:])
            let handle = handle
            let idle = idleWaiters.withLock { waiters -> Bool in
                if Self.call("state", data, on: handle)["idle"] as? Bool ?? true { return true }
                waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Stops deriving ids and recording; later commands are ordinary.
    public func close() {
        _ = call("close")
    }

    /// False once the action answered (``close()``): nobody reads what a later command records.
    public var isOpen: Bool { field("open") as? Bool ?? false }

    public var failures: [Failure] {
        (field("failures") as? [[String: Any]] ?? []).map {
            Failure(label: $0["label"] as? String ?? "", message: $0["message"] as? String ?? "",
                    mayHaveApplied: $0["may_have_applied"] as? Bool ?? false,
                    terminalMayAppear: $0["terminal_may_appear"] as? Bool ?? false)
        }
    }

    public var created: [DaemonCreatedObject] {
        (field("created") as? [[String: Any]] ?? []).compactMap { object in
            guard let kind = (object["kind"] as? String).flatMap(DaemonCreatedObject.Kind.init(rawValue:)),
                  let id = object["id"] as? String else { return nil }
            return DaemonCreatedObject(kind, id)
        }
    }

    public var ticketCount: UInt64 { (field("ticket_count") as? NSNumber)?.uint64Value ?? 0 }

    /// Every machine's barrier: the event sequence that covers every command's echo, by machine id.
    public var barriers: [String: UInt64] {
        (field("barriers") as? [String: NSNumber] ?? [:]).mapValues(\.uint64Value)
    }

    // MARK: - Idempotency

    /// The next `mutation_id` for this action: derived from the idempotency
    /// key and the mutation's ordinal, or nil (a fresh id) without a key or
    /// once closed (SHA-256 of both as a UUIDv4, src/scope.rs `derived_uuid`).
    public func nextMutationID() -> String? {
        guard idempotencyKey != nil else { return nil }
        return call("next_mutation_id")["id"] as? String
    }

    /// The next generated id of `kind` (a new workspace key, a reserved
    /// terminal id) for this action, derived like ``nextMutationID()``.
    public func nextDerivedUUID(_ kind: String) -> UUID? {
        guard idempotencyKey != nil else { return nil }
        return (call("next_derived", ["kind": kind])["uuid"] as? String).flatMap(UUID.init(uuidString:))
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
