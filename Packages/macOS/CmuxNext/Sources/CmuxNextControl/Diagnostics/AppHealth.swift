#if canImport(CCmuxHealthFFI)
import CCmuxHealthFFI
#endif
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import os

/// The app's health (the shared health contract; Leo, 2026-11-09: "figure out how to auto repair that
/// kinda thing, and even better of course, prevent it from ever happening in the future"): which part
/// of the app is slow, stuck or failed, and its repair. Every rule is the Rust health model's
/// (cmux-tui/crates/cmux-health-core, module `CCmuxHealthFFI`); this type is its thin host:
///
/// - owners feed signals (``beat(_:)``, ``event(_:_:value:)``, ``visibility(_:visible:)``...) from
///   whichever thread they are on: one short lock and one JSON call, never a wait;
/// - it runs ONE one-shot timer (``DemandTimer`` on the injected clock) to the model's `nextTickMs`,
///   re-armed after every call; a null `nextTickMs` cancels it (the stop condition), so a healthy
///   app with no armed deadline has no timer;
/// - each `tick` action goes to the repair its owner registered for that part's kind
///   (``setRepair(_:_:)``), off the main thread, and its result goes back (`repairResult`);
/// - the snapshot (only non-healthy parts, so it stays small) goes to subscribers only when it
///   changed.
///
/// Times are ms on one monotonic clock: the injected clock's time since this object was made.
/// Lives in CmuxNextControl's Diagnostics next to ``MainThreadWatchdog``: the control socket serves
/// it (`debug.health`), and CmuxNextDaemonService feeds it directly; CmuxNextDaemon and
/// CmuxNextPages, which this package sits above, feed it through their own small hooks.
public final class AppHealth: Sendable {
    /// The contract's part kinds.
    public enum Kind: String, Sendable, CaseIterable {
        case page, renderer, sessionDaemon, acpmux, pageHost, roster
    }

    /// The contract's states, best first (so `<` reads "better than").
    public enum State: String, Sendable, Comparable {
        case healthy, slow, repairing, stuck, failed

        private var rank: Int {
            switch self {
            case .healthy: 0
            case .slow: 1
            case .repairing: 2
            case .stuck: 3
            case .failed: 4
            }
        }

        public static func < (lhs: State, rhs: State) -> Bool { lhs.rank < rhs.rank }
    }

    /// What the host does to a part (the contract's `action`).
    public enum Repair: String, Sendable {
        case reloadPage, restartRenderer, reconnect, restartConnection, restartPageHost, holdReplace, none
    }

    /// The contract's events (`event {id, event}`).
    public enum Event: String, Sendable {
        case crashed, loaded, unresponsive, responsive, connected, disconnected, loadFailed, listenerMissing
        case started, ready, exited, restoreProgress, restoreStarted, restoreFinished
    }

    /// One thing to do, from `tick` or `repairNow`.
    public struct Action: Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var action: Repair
        public var attempt: Int
        /// The model's token for this action, sent back with its result so a late result never
        /// lands on a newer attempt (nil from a model that sends none).
        public var token: UInt64?

        public init(id: String, kind: Kind, action: Repair, attempt: Int, token: UInt64? = nil) {
            self.id = id
            self.kind = kind
            self.action = action
            self.attempt = attempt
            self.token = token
        }
    }

    /// What a native indicator draws from one snapshot: nil when it is quiet (every part healthy and
    /// no action waits). The words come from the model (`label`, `detail`); the indicator only
    /// localizes the state.
    public struct Headline: Sendable, Equatable {
        /// The worst part (worst state, longest in it first); nil when only pending actions show.
        public var partID: String?
        public var label: String?
        public var state: State?
        public var detail: String?
        public var canRepair: Bool
        /// The newest pending action's label ("close Background task"), and how many wait.
        public var pending: String?
        public var pendingCount: Int
    }

    /// An owner's repair for one action: true when it ran (the part's own signal, not this, ends the
    /// episode). Called off the main actor; hop where AppKit is needed.
    public typealias RepairHandler = @Sendable (Action) async -> Bool
    /// A debug fault for one part (`debug.health.inject`): true when the owner made it.
    public typealias Injector = @Sendable (_ id: String, _ fault: String) async -> Bool

    /// The single parts' ids.
    public static let sessionDaemonID = "sessionDaemon"
    public static let acpmuxID = "acpmux"
    public static let pageHostID = "pageHost"
    public static let rosterID = "roster"

    private struct Box {
        let model = Model()
        /// The deadline the timer is armed to (model ms); nil: no timer.
        var armedAt: UInt64?
        var snapshot: JSONValue = AppHealth.quietSnapshot
        /// Bumped with each new snapshot; delivery drops one older than the last delivered.
        var version: UInt64 = 0
        var subscribers: [UInt64: @Sendable (JSONValue) -> Void] = [:]
        var nextSubscriber: UInt64 = 0
        var repairs: [Kind: RepairHandler] = [:]
        var injectors: [Kind: Injector] = [:]
        /// When the model said a restoring daemon loops (`holdReplace`), until an owner is ready.
        var holdReplaceAt: UInt64?
        /// The last restore progress (model ms), until an owner is ready or exits.
        var restoreProgressAt: UInt64?
    }

    private let box = Mutex(Box())
    /// The version last delivered to the subscribers. Delivery runs under this lock, outside the
    /// model's, so two ops racing to publish never land an older snapshot after a newer one.
    private let delivered = Mutex<UInt64>(0)
    private let timer: DemandTimer
    private let elapsed: @Sendable () -> Duration
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.health")

    /// - Parameter clock: The timer's clock and the model's ms (tests pass a manual clock). The
    ///   default does not advance while the Mac sleeps: page heartbeats stop then too, so a wake never
    ///   reads as every page silent.
    public init(clock: any Clock<Duration> = SuspendingClock()) {
        timer = DemandTimer(owner: "app.health.tick", clock: clock)
        elapsed = Self.elapsedSince(now: clock)
    }

    deinit {
        timer.cancel()
    }

    /// Whether the Rust model is linked (a pinned app FFI without `CCmuxHealthFFI` leaves this type inert).
    public var isModelLinked: Bool { box.withLock { $0.model.isLinked } }

    /// Whether the one timer is armed (tests: no deadline, no timer).
    public var isTimerArmed: Bool { timer.isScheduled }

    // MARK: Feeds

    /// Starts timing `id`. A second register of the same id only updates its label.
    public func register(_ id: String, kind: Kind, label: String, visible: Bool = true) {
        run("register", ["id": .string(id), "kind": .string(kind.rawValue), "label": .string(label), "visible": .bool(visible)])
    }

    public func unregister(_ id: String) {
        run("unregister", ["id": .string(id)], timed: false)
    }

    /// The part answered (a page's heartbeat, an answered liveness ask).
    public func beat(_ id: String) {
        run("beat", ["id": .string(id)])
    }

    /// Input counters (monotonic): sent to the part, and handled by it.
    public func input(_ id: String, sent: UInt64, handled: UInt64) {
        run("input", ["id": .string(id), "sent": .number(Double(sent)), "handled": .number(Double(handled))])
    }

    /// A hidden part is never timed; shown, its deadline arms from now.
    public func visibility(_ id: String, visible: Bool) {
        run("visibility", ["id": .string(id), "visible": .bool(visible)])
    }

    public func event(_ id: String, _ event: Event, pid: Int32? = nil, value: UInt64? = nil) {
        var fields: [String: JSONValue] = ["id": .string(id), "event": .string(event.rawValue)]
        if let pid { fields["pid"] = .number(Double(pid)) }
        if let value { fields["value"] = .number(Double(value)) }
        if id == Self.sessionDaemonID {
            let now = nowMs()
            box.withLock { box in
                switch event {
                // A daemon that is ready again is no restore to protect.
                case .ready:
                    box.holdReplaceAt = nil
                    box.restoreProgressAt = nil
                case .exited: box.restoreProgressAt = nil
                case .restoreProgress: box.restoreProgressAt = now
                default: break
                }
            }
        }
        run("event", fields)
    }

    // The session daemon's seam (part `sessionDaemon`). The launcher's ensure reports started, ready
    // and exited (`DaemonLauncher.HealthSignal`); `DaemonRecovery.restoring` (lane/app-session-self-heal,
    // which parses the owner's `--restore-progress` lines) calls ``noteDaemonRestoring(pid:)`` on each
    // restore report once that lane lands. No other code reads restore progress.

    /// `server ensure` is starting an owner (three in 10 minutes with no ready is a start loop).
    public func noteDaemonStarted(pid: Int32? = nil) { event(Self.sessionDaemonID, .started, pid: pid) }

    /// An owner answers: ends a restore and clears the start loop and ``holdsReplace``.
    public func noteDaemonReady(pid: Int32) { event(Self.sessionDaemonID, .ready, pid: pid) }

    /// The owner an ensure started did not become ready.
    public func noteDaemonExited(pid: Int32? = nil) { event(Self.sessionDaemonID, .exited, pid: pid) }

    /// The owner is restoring sessions and just reported it (a liveness line, no value): called by
    /// `DaemonRecovery.restoring` on each restore report.
    public func noteDaemonRestoring(pid: Int32?) { event(Self.sessionDaemonID, .restoreProgress, pid: pid) }

    /// Bytes on disk (the session daemon's registry, WAL and output cleanup).
    public func size(_ id: String, bytes: UInt64) {
        run("size", ["id": .string(id), "bytes": .number(Double(bytes))])
    }

    /// A user action queued while its target is unreachable (no apply-then-revert): shown pending
    /// until ``pendingDone(id:ok:)``. `label` is a verb phrase ("close Background task"). Called by the
    /// owners of queued intents (lane/no-revert-while-offline).
    public func notePending(id: String, label: String) {
        run("pending", ["id": .string(id), "label": .string(label)])
    }

    public func pendingDone(id: String, ok: Bool) {
        run("pendingDone", ["id": .string(id), "ok": .bool(ok)])
    }

    /// The person's one click (Repair / Repair now): clears the cap and starts the ladder at step 1.
    public func repairNow(id: String) {
        dispatch(actions(of: run("repairNow", ["id": .string(id)])))
    }

    // MARK: Owners

    /// The repair for every part of `kind` (nil removes it). An action with no repair reports failed.
    public func setRepair(_ kind: Kind, _ handler: RepairHandler?) {
        box.withLock { $0.repairs[kind] = handler }
    }

    /// The debug fault maker for every part of `kind` (`debug.health.inject`; Debug and tagged builds).
    public func setInjector(_ kind: Kind, _ injector: Injector?) {
        box.withLock { $0.injectors[kind] = injector }
    }

    /// Makes `fault` happen for real on part `id` (`hang`, `resume`): false when its kind has no
    /// injector or the owner could not.
    public func inject(id: String, fault: String) async -> Bool {
        let kind = Self.kind(ofID: id)
        guard let kind, let injector = box.withLock({ $0.injectors[kind] }) else { return false }
        _ = run("inject", ["id": .string(id), "fault": .string(fault)], timed: false)
        return await injector(id, fault)
    }

    /// The kind an id names (`page:42` is a page).
    public static func kind(ofID id: String) -> Kind? {
        if let colon = id.firstIndex(of: ":") { return Kind(rawValue: String(id.prefix(upTo: colon))) }
        return Kind(rawValue: id)
    }

    /// True while the session daemon restores and still makes progress (its last progress within
    /// ``restoreProgressWindowMs``, the model's no-progress bound `DAEMON_STALL_MS`). The model's
    /// start-loop hold (`holdReplace`) counts as progress at the moment it came, so it ends the same
    /// way: an owner is ready, or the bound passes with no progress (a stalled loop is not protected).
    /// Read-only: the replace paths consult it before they kill or replace an owner; this type never
    /// does either.
    public var holdsReplace: Bool {
        let now = nowMs()
        return box.withLock { box in
            [box.holdReplaceAt, box.restoreProgressAt].compactMap { $0 }.max().map { now &- $0 < Self.restoreProgressWindowMs } == true
        }
    }

    /// A restore with no progress this long is stuck, not protected (cmux-health-core's bound).
    static let restoreProgressWindowMs: UInt64 = 120_000

    // MARK: Snapshot

    /// The current snapshot (the contract's `Snapshot`).
    public var snapshot: JSONValue { box.withLock { $0.snapshot } }

    /// The indicator's line from the current snapshot.
    public var headline: Headline? { Self.headline(of: snapshot) }

    /// Calls `onChange` with the current snapshot now and with each changed one after it, on the
    /// thread that changed it; hop where needed. Snapshots arrive in order, never an older after a
    /// newer; `onChange` runs under the delivery lock, so it must not call back into this model
    /// synchronously. Returns the token for ``unsubscribe(_:)``.
    @discardableResult
    public func subscribe(_ onChange: @escaping @Sendable (JSONValue) -> Void) -> UInt64 {
        let (token, current, version) = box.withLock { box -> (UInt64, JSONValue, UInt64) in
            box.nextSubscriber += 1
            box.subscribers[box.nextSubscriber] = onChange
            return (box.nextSubscriber, box.snapshot, box.version)
        }
        // A newer snapshot already delivered reached this subscriber too.
        delivered.withLock { last in
            if version >= last { onChange(current) }
        }
        return token
    }

    public func unsubscribe(_ token: UInt64) {
        box.withLock { _ = $0.subscribers.removeValue(forKey: token) }
    }

    static let quietSnapshot: JSONValue = ["worst": "healthy", "parts": [], "receipts": [], "pending": [], "pendingMore": 0]

    /// The worst part (worst state, the longest in it first), else the newest pending action. A part that is
    /// only slow is left out: it still answers, and if it stops the model makes it stuck and repairs it, so
    /// a line for it named nothing the person could do (Leo, 2026-11-11: "slow indicator on the bottom left
    /// is uselsss"; a busy Mac late on a page's heartbeat showed "Agent pane: Slow" for seconds at a time).
    /// The popover still lists it.
    public static func headline(of snapshot: JSONValue) -> Headline? {
        let parts = (snapshot["parts"]?.arrayValue ?? []).filter { State(rawValue: $0["state"]?.stringValue ?? "") ?? .healthy > .slow }
        let pending = snapshot["pending"]?.arrayValue ?? []
        let pendingCount = pending.count + (snapshot["pendingMore"]?.intValue ?? 0)
        let worst = parts.max { a, b in
            let (sa, sb) = (State(rawValue: a["state"]?.stringValue ?? "") ?? .healthy, State(rawValue: b["state"]?.stringValue ?? "") ?? .healthy)
            if sa != sb { return sa < sb }
            return (a["sinceMs"]?.doubleValue ?? 0) > (b["sinceMs"]?.doubleValue ?? 0)
        }
        guard worst != nil || pendingCount > 0 else { return nil }
        return Headline(partID: worst?["id"]?.stringValue, label: worst?["label"]?.stringValue,
                        state: worst.flatMap { State(rawValue: $0["state"]?.stringValue ?? "") },
                        detail: worst?["detail"]?.stringValue, canRepair: worst?["canRepair"]?.boolValue ?? false,
                        pending: pending.first?["label"]?.stringValue, pendingCount: pendingCount)
    }

    // MARK: The model

    /// Now on the model's clock (ms since this object was made).
    private func nowMs() -> UInt64 {
        let (seconds, attoseconds) = elapsed().components
        return UInt64(clamping: seconds) &* 1000 &+ UInt64(clamping: attoseconds / 1_000_000_000_000_000)
    }

    private static func elapsedSince<C: Clock<Duration>>(now clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// Runs one op under the lock, re-arms the one timer to its `nextTickMs`, and publishes the
    /// snapshot when it changed (outside the lock). `timed` ops get `nowMs`.
    @discardableResult
    private func run(_ op: String, _ fields: [String: JSONValue], timed: Bool = true) -> JSONValue? {
        let now = nowMs()
        var request = fields
        if timed { request["nowMs"] = .number(Double(now)) }
        let body = Data(JSONValue.object(request).compactText.utf8)
        let (reply, publish) = box.withLock { box -> (JSONValue?, (UInt64, JSONValue, [@Sendable (JSONValue) -> Void])?) in
            guard let data = box.model.call(op, body), let reply = try? JSONValue.parse(data) else { return (nil, nil) }
            if reply["actions"]?.arrayValue?.contains(where: { $0["action"]?.stringValue == Repair.holdReplace.rawValue }) == true {
                box.holdReplaceAt = now
            }
            if reply["nextTickMs"] != nil { arm(&box, next: reply["nextTickMs"]?.doubleValue.flatMap { $0 > 0 ? UInt64(exactly: $0.rounded(.up)) : 0 }, now: now) }
            // Compared by value: the first op's quiet snapshot equals the initial one and publishes nothing.
            guard let data = box.model.call("snapshot", Data()), let snapshot = try? JSONValue.parse(data),
                  snapshot != box.snapshot else { return (reply, nil) }
            box.snapshot = snapshot
            box.version += 1
            return (reply, (box.version, snapshot, Array(box.subscribers.values)))
        }
        if reply == nil, box.withLock({ $0.model.isLinked }) {
            logger.fault("health op \(op, privacy: .public) was refused")
        }
        if let (version, snapshot, subscribers) = publish {
            delivered.withLock { last in
                guard version > last else { return }
                last = version
                for subscriber in subscribers { subscriber(snapshot) }
            }
        }
        return reply
    }

    /// The one timer: armed to `next` (model ms), replaced only when the deadline moved; cancelled
    /// when the model has none.
    private func arm(_ box: inout Box, next: UInt64?, now: UInt64) {
        guard box.armedAt != next || (next != nil && !timer.isScheduled) else { return }
        box.armedAt = next
        guard let next else {
            timer.cancel()
            return
        }
        let delay = Duration.milliseconds(Int64(clamping: next > now ? next - now : 0))
        // wakeup-allow: one one-shot deadline at the model's next expiry; cancelled when it has none.
        timer.schedule(after: delay) { [weak self] in self?.tick() }
    }

    private func tick() {
        box.withLock { $0.armedAt = nil }
        dispatch(actions(of: run("tick", [:])))
    }

    private func actions(of reply: JSONValue?) -> [Action] {
        (reply?["actions"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue, let kind = Kind(rawValue: value["kind"]?.stringValue ?? ""),
                  let action = Repair(rawValue: value["action"]?.stringValue ?? "") else { return nil }
            let token = value["token"]?.doubleValue.flatMap { UInt64(exactly: $0) }
            return Action(id: id, kind: kind, action: action, attempt: value["attempt"]?.intValue ?? 1, token: token)
        }
    }

    /// Each action to its kind's repair, one task each; `holdReplace` is a flag (``holdsReplace``), not a repair.
    private func dispatch(_ actions: [Action]) {
        for action in actions where action.action != .holdReplace && action.action != .none {
            guard let handler = box.withLock({ $0.repairs[action.kind] }) else {
                logger.error("health: no repair for \(action.kind.rawValue, privacy: .public) \(action.action.rawValue, privacy: .public)")
                report(action, ok: false)
                continue
            }
            logger.notice("health: \(action.action.rawValue, privacy: .public) for \(action.kind.rawValue, privacy: .public), attempt \(action.attempt)")
            // task-owner: one repair per model action; ends when the owner's handler returns (each is bounded).
            Task(priority: .utility) { [weak self] in
                let ok = await handler(action)
                self?.report(action, ok: ok)
            }
        }
    }

    private func report(_ action: Action, ok: Bool) {
        var fields: [String: JSONValue] = ["id": .string(action.id), "action": .string(action.action.rawValue), "ok": .bool(ok)]
        if let token = action.token { fields["token"] = .number(Double(token)) }
        run("repairResult", fields)
    }
}

/// The Rust model's handle (one per ``AppHealth``, only touched under its lock).
private final class Model {
    #if canImport(CCmuxHealthFFI)
    private let handle: OpaquePointer?

    init() {
        handle = cmux_health_new()
    }

    deinit {
        if let handle { cmux_health_free(handle) }
    }

    var isLinked: Bool { handle != nil }

    /// One op's reply (JSON), nil when the model refused it.
    func call(_ op: String, _ request: Data) -> Data? {
        guard let handle else { return nil }
        var out = CmuxHealthBytes(ptr: nil, len: 0)
        let code: Int32 = request.withUnsafeBytes { raw in
            op.withCString { name in
                cmux_health_call(handle, name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
            }
        }
        defer { cmux_health_bytes_free(out) }
        guard code == CMUX_HEALTH_OK else { return nil }
        guard let bytes = out.ptr, out.len > 0 else { return Data() }
        return Data(bytes: bytes, count: out.len)
    }
    #else
    var isLinked: Bool { false }

    func call(_ op: String, _ request: Data) -> Data? { nil }
    #endif
}
