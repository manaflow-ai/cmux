import CmuxNextDaemon
import CryptoKit
import Foundation

/// The single owner of the local feed handoff (plans/cmux-next/feed.md
/// section 5 rule 3 and 9.1, B1 to B5). The bundled daemon owns every local
/// item; this driver moves the ones the settings allow to FeedDO, because the
/// app holds the cloud credential: `feed-local-handoff-begin` (the daemon
/// freezes the item as `handing_off`), `feed.adopt` with the idempotency key
/// `adopt:<item>`, then `feed-local-handoff-done {home: cloud}`.
///
/// No queue lives in memory: each pass lists the daemon's `handing_off`
/// items first (B3), then its open unread ones. A failure leaves the item
/// `handing_off`, and the next pass (the next launch, the next notification)
/// sends the same key again; FeedDO's ledger makes that retry safe. Passes
/// run on events only (activation, a new local item), never on a timer.
///
/// Active only when `enabled` (off in shipped builds, `isEnabledByDefault`),
/// the local daemon serves `feed-local-owner-v1`, the user is signed in, and
/// the app holds an install credential (`feed.adopt` is an install-only op).
/// Otherwise the step-1 bridge (`FeedNotificationBridge`) keeps mirroring (B1).
@MainActor
final class FeedHandoffDriver {
    /// The local daemon's feed-owner commands.
    struct Daemon {
        var serves: @MainActor () -> Bool
        var list: @MainActor (_ state: FeedLocalItem.State, _ unreadOnly: Bool) async throws -> [FeedLocalItem]
        var begin: @MainActor (_ item: String) async throws -> FeedLocalItem
        var done: @MainActor (_ item: String, _ home: String) async throws -> FeedLocalItem
    }

    typealias Owner = FeedNotificationBridge.Owner

    /// The gate for shipped builds. OFF until P8 slice 3 lands: the daemon
    /// must accept `feed-local-handoff-begin`/`-done` only from the frontend
    /// (user) actor before the app starts handoffs (daemon owner's review
    /// condition, feed.md 9.1). Tests construct the driver with the gate on.
    static let isEnabledByDefault = false

    /// The home FeedDO items get.
    static let home = "cloud"
    /// Client cap on adopts: terminal spam must not use up the owner's per-poster limit.
    static let maxAdoptsPerMinute = 30
    /// Items read while they were moving, read in the cloud once they moved (bounded).
    static let maxPendingReads = 500

    private let enabled: Bool
    private let daemon: Daemon
    private let owner: Owner
    private let isSignedIn: @MainActor () -> Bool
    private let installID: @MainActor () -> String?
    private let policy: @MainActor () -> FeedHandoffPolicy
    private let now: @MainActor () -> Date
    /// The running pass, and whether an event asked for another one meanwhile.
    private var pass: Task<Void, Never>?
    private var again = false
    /// Cloud reads in flight; each removes itself when it settles.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Local ids the user read while they were handing off (`feed.moving`).
    private var readAfterMove: Set<String> = []
    private var minute: (start: Date, count: Int)?
    /// Recent handoffs and failures (for `debug.notifications`).
    private(set) var log: [String] = []
    private static let logLimit = 32

    init(enabled: Bool = FeedHandoffDriver.isEnabledByDefault, daemon: Daemon, owner: @escaping Owner, isSignedIn: @escaping @MainActor () -> Bool,
         installID: @escaping @MainActor () -> String?, policy: @escaping @MainActor () -> FeedHandoffPolicy,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.enabled = enabled
        self.daemon = daemon
        self.owner = owner
        self.isSignedIn = isSignedIn
        self.installID = installID
        self.policy = policy
        self.now = now
    }

    /// Whether the driver replaces the step-1 bridge right now.
    var isActive: Bool { enabled && daemon.serves() && isSignedIn() && installID() != nil }

    /// Runs one pass (at activation and on each new local item). A pass that
    /// is running finishes first; one more pass follows it.
    func run() {
        guard isActive else { return }
        guard pass == nil else {
            again = true
            return
        }
        // task-owner: FeedHandoffDriver.pass: one handoff pass; it clears itself and starts the follow-up pass an event asked for.
        pass = Task { [weak self] in
            await self?.handOffAll()
            guard let self else { return }
            pass = nil
            if again {
                again = false
                run()
            }
        }
    }

    /// The daemon refused to read these items on an ack (B5): moved items
    /// are read in the cloud at once (one call; nothing queues while signed
    /// out or offline), items still moving once their move completes.
    func acknowledged(_ refused: [AckTabNotificationsRequest.Refused]) {
        for item in refused where item.code == "feed.moving" && readAfterMove.count < Self.maxPendingReads {
            readAfterMove.insert(item.item)
        }
        let moved = refused.filter { $0.code == "owner.unreachable" }.map(\.item)
        guard !moved.isEmpty else { return }
        readInCloud(moved)
    }

    /// Waits until no pass or cloud read is in flight (tests).
    func drain() async {
        while let task = pass ?? running.values.first { await task.value }
    }

    // MARK: Pass

    private func handOffAll() async {
        guard let install = installID() else { return }
        do {
            for item in try await daemon.list(.handingOff, false) {
                guard await adopt(item, install: install, content: policy().frozenContent(for: item)) else { return }
            }
            let policy = policy()
            for item in try await daemon.list(.open, true) {
                guard let content = policy.content(for: item) else { continue }
                guard spendBudget() else {
                    note("pass stopped: over \(Self.maxAdoptsPerMinute) adopts per minute")
                    return
                }
                let frozen: FeedLocalItem
                do {
                    frozen = try await daemon.begin(item.id)
                } catch let error where Self.isItemRefusal(error) {
                    note("begin \(item.id) refused: \(Self.describe(error))")
                    continue
                }
                guard await adopt(frozen, install: install, content: content) else { return }
            }
        } catch {
            note("pass stopped: \(Self.describe(error))")
        }
    }

    /// Sends `feed.adopt` for a frozen item, then records the move. Returns
    /// false when the pass should stop (the owner or the daemon is unreachable).
    private func adopt(_ item: FeedLocalItem, install: String, content: (title: String, body: String)) async -> Bool {
        let body = Self.adoptBody(item, install: install, content: content, now: now())
        do {
            _ = try await owner("v1/ops", body)
        } catch FeedServiceError.owner(let code, _) {
            note("adopt \(item.id) refused: \(code)")
            return true
        } catch {
            note("adopt \(item.id) failed: \(Self.describe(error))")
            return false
        }
        do {
            _ = try await daemon.done(item.id, Self.home)
        } catch {
            note("done \(item.id) failed: \(Self.describe(error))")
            return Self.isItemRefusal(error)
        }
        note("moved \(item.id)")
        if readAfterMove.remove(item.id) != nil { readInCloud([item.id]) }
        return true
    }

    private func spendBudget() -> Bool {
        let date = now()
        if let current = minute, date.timeIntervalSince(current.start) < 60 {
            guard current.count < Self.maxAdoptsPerMinute else { return false }
            minute = (current.start, current.count + 1)
        } else {
            minute = (date, 1)
        }
        return true
    }

    private func readInCloud(_ local: [String]) {
        guard isSignedIn(), let install = installID() else {
            note("read \(local.count) moved: signed out (not queued)")
            return
        }
        let items = local.prefix(256).map { Self.cloudID(install: install, local: $0) }
        let body: [String: Any] = ["op": "feed.read", "params": ["items": Array(items)],
                                   "idempotency_key": UUID().uuidString, "origin": "user"]
        note("read moved \(local.joined(separator: ","))")
        let id = UUID()
        // task-owner: FeedHandoffDriver.running: one feed.read; a failure only leaves the cloud copy unread (U5: nothing queues).
        running[id] = Task { [weak self, owner] in
            do { _ = try await owner("v1/ops", body) } catch { self?.note("read failed: \(Self.describe(error))") }
            self?.running[id] = nil
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    // MARK: Wire

    /// The FeedDO id of a local item: stable per install and local id, so
    /// every retry and every later read names the same cloud item.
    nonisolated static func cloudID(install: String, local: String) -> String {
        let digest = SHA256.hash(data: Data("\(install)\n\(local)".utf8))
        return "fi_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    /// `feed.adopt {item}` for a frozen local item: the full cloud item,
    /// homed on this install, with `content` (already filtered and scrubbed).
    nonisolated static func adoptBody(_ item: FeedLocalItem, install: String, content: (title: String, body: String),
                                      now: Date) -> [String: Any] {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let created = min(Int(item.createdAtMs), nowMs)
        let updated = max(created, min(Int(item.updatedAtMs), nowMs))
        let high = item.level == "error"
        var context: [String: Any] = [:]
        for (key, value) in [("workspace", item.context.workspace), ("tab", item.context.tab), ("terminal", item.context.terminal)] {
            if let value, !value.isEmpty { context[key] = String(value.prefix(128)) }
        }
        let title = content.title.isEmpty ? "cmux" : String(content.title.prefix(200))
        let cloud: [String: Any] = [
            "id": cloudID(install: install, local: item.id),
            "home": "local:\(install)",
            "type": "notice",
            "kind": "notice",
            "title": title,
            "body": String(content.body.prefix(4096)),
            "priority": high ? "high" : "normal",
            "dedupe_key": String(item.dedupeKey.prefix(200)),
            "thread": orNull(item.context.tab.map { String("tab:\($0)".prefix(200)) }),
            "context": context,
            "attachments": [Any](),
            "actions": [Any](),
            "open": NSNull(),
            // A fixed label: never the tab title, which can hold a command line.
            "poster": ["kind": "system", "scope": "inst:\(install)", "label": String(item.source.prefix(80)), "install": install],
            "state": "open",
            "answer": NSNull(),
            "cancel": NSNull(),
            "needs_mac": false,
            "expires_at": created + 7 * 24 * 3_600_000,
            "read_at": orNull(item.readAtMs.map { min(Int($0), nowMs) }),
            "seen_at": NSNull(),
            "archived_at": NSNull(),
            "snoozed_until": NSNull(),
            // The owner's default delays (feed.md 7.3); it never pushes earlier than the adopt.
            "push_due_at": created + (high ? 20_000 : 120_000),
            "pushed_at": NSNull(),
            "count": Int(item.count),
            "order": 0,
            "revision": 1,
            "created_at": created,
            "updated_at": updated,
            "closed_at": NSNull(),
        ]
        return ["op": "feed.adopt", "params": ["item": cloud], "idempotency_key": "adopt:\(item.id)", "origin": "script"]
    }

    nonisolated private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// A daemon refusal about one item (it moved, vanished or changed state),
    /// as opposed to a lost connection.
    nonisolated static func isItemRefusal(_ error: any Error) -> Bool {
        guard case let DaemonError.command(_, _, code, _, _) = error else { return false }
        return ["feed.invalid_state", "feed.moving", "not_found", "owner.unreachable"].contains(code ?? "")
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        if case let FeedServiceError.owner(code, _) = error { return code }
        if case let DaemonError.command(_, _, code?, _, _) = error { return code }
        return String(describing: error).prefix(120).description
    }
}
