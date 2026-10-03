import CmuxNextDaemon
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
/// sends the same key with the same body (a pure function of the frozen
/// item); FeedDO's ledger makes that retry safe. Passes run on events only
/// (activation, a new local item), never on a timer.
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
    /// Bound of each in-memory id set (hints only; the daemon holds the state).
    static let maxTracked = 500
    /// Owner codes that say "not now" for every item: the pass stops.
    static let stopCodes: Set<String> = ["feed.rate_limited", "feed.full", "rate_limited", "owner.unavailable"]

    private let enabled: Bool
    private let daemon: Daemon
    private let owner: Owner
    private let isSignedIn: @MainActor () -> Bool
    private let installID: @MainActor () -> String?
    private let policy: @MainActor () -> FeedHandoffPolicy
    /// The first time the driver ran for an install (ms, persisted by the
    /// caller): older open items stay local, so nothing the step-1 bridge
    /// already posted is adopted a second time.
    private let since: @MainActor (_ install: String) -> UInt64
    private let now: @MainActor () -> Date
    /// The running pass, and whether an event asked for another one meanwhile.
    private var pass: Task<Void, Never>?
    private var again = false
    /// Cloud requests in flight; each removes itself when it settles.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Local ids the user read while they were handing off (`feed.moving`).
    private var readAfterMove: Set<String> = []
    /// Local ids this run moved (an ack refusal may arrive after the move).
    private var recentlyMoved: Set<String> = []
    /// Items the owner refused for good this run: not resent until the next launch.
    private var refused: Set<String> = []
    /// Terminals (`term_…`) whose newest notification did not alert on this
    /// Mac (pane in view, app active, banners off): their item stays local.
    private var withheld: Set<String> = []
    private var minute: (start: Date, count: Int)?
    /// Recent handoffs and failures (for `debug.notifications`).
    private(set) var log: [String] = []
    private static let logLimit = 32

    init(enabled: Bool = FeedHandoffDriver.isEnabledByDefault, daemon: Daemon, owner: @escaping Owner,
         isSignedIn: @escaping @MainActor () -> Bool, installID: @escaping @MainActor () -> String?,
         policy: @escaping @MainActor () -> FeedHandoffPolicy, since: @escaping @MainActor (String) -> UInt64 = { _ in 0 },
         now: @escaping @MainActor () -> Date = Date.init) {
        self.enabled = enabled
        self.daemon = daemon
        self.owner = owner
        self.isSignedIn = isSignedIn
        self.installID = installID
        self.policy = policy
        self.since = since
        self.now = now
    }

    /// Whether the driver replaces the step-1 bridge right now.
    var isActive: Bool { enabled && daemon.serves() && isSignedIn() && installID() != nil }

    /// A notification arrived for `terminal`: whether it alerted on this Mac
    /// (the arrival decision). A withheld terminal's item stays local until
    /// a later notification there alerts.
    func noteArrival(terminal: String?, alerted: Bool) {
        guard let terminal else { return }
        if alerted {
            withheld.remove(terminal)
        } else if withheld.count < Self.maxTracked {
            withheld.insert(terminal)
        }
    }

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
    /// are read in the cloud at once (nothing queues while signed out or
    /// offline), items still moving once their move completes.
    func acknowledged(_ refusals: [AckTabNotificationsRequest.Refused]) {
        var moved = refusals.filter { $0.code == "owner.unreachable" }.map(\.item)
        for refusal in refusals where refusal.code == "feed.moving" {
            if recentlyMoved.contains(refusal.item) {
                moved.append(refusal.item)
            } else if readAfterMove.count < Self.maxTracked {
                readAfterMove.insert(refusal.item)
            }
        }
        if !moved.isEmpty { readInCloud(moved) }
    }

    /// Waits until no pass or cloud request is in flight (tests).
    func drain() async {
        while let task = pass ?? running.values.first { await task.value }
    }

    // MARK: Pass

    private func handOffAll() async {
        guard let install = installID() else { return }
        do {
            for item in try await daemon.list(.handingOff, false) where !refused.contains(item.id) {
                guard await adopt(item, install: install) else { return }
            }
            let policy = policy()
            let floor = since(install)
            for item in try await daemon.list(.open, true) {
                guard item.createdAtMs >= floor, !(item.context.terminal.map { withheld.contains($0) } ?? false),
                      policy.content(for: item) != nil else { continue }
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
                guard await adopt(frozen, install: install) else { return }
            }
        } catch {
            note("pass stopped: \(Self.describe(error))")
        }
    }

    /// Sends `feed.adopt` for a frozen item, then records the move. Returns
    /// false when the pass should stop (owner or daemon unreachable, a limit).
    private func adopt(_ item: FeedLocalItem, install: String) async -> Bool {
        let body = Self.adoptBody(item, install: install, content: policy().frozenContent(for: item))
        do {
            _ = try await owner("v1/ops", body)
        } catch FeedServiceError.owner(let code, _) where code == "idempotency.conflict" {
            // An earlier attempt with other text committed: confirm the cloud item is ours.
            guard await adoptedEarlier(item, install: install) else { return false }
        } catch FeedServiceError.owner(let code, _) {
            note("adopt \(item.id) refused: \(code)")
            if Self.stopCodes.contains(code) || code.hasPrefix("auth.") { return false }
            if refused.count < Self.maxTracked { refused.insert(item.id) }
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
        if recentlyMoved.count >= Self.maxTracked { recentlyMoved.removeAll() }
        recentlyMoved.insert(item.id)
        if readAfterMove.remove(item.id) != nil { readInCloud([item.id]) }
        return true
    }

    /// Whether FeedDO already holds `item` from this install (`feed.get` on the derived id).
    private func adoptedEarlier(_ item: FeedLocalItem, install: String) async -> Bool {
        let id = Self.cloudID(install: install, local: item.id)
        do {
            let reply = try await owner("v1/read", ["op": "feed.get", "params": ["item": id]])
            let cloud = (reply["value"] as? [String: Any])?["item"] as? [String: Any]
            let poster = cloud?["poster"] as? [String: Any]
            if poster?["install"] as? String == install { return true }
            note("adopt \(item.id): conflict with another item")
        } catch {
            note("adopt \(item.id): conflict, get failed: \(Self.describe(error))")
        }
        return false
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
        note("read moved \(local.joined(separator: ","))")
        let ids = local.map { Self.cloudID(install: install, local: $0) }
        for start in stride(from: 0, to: ids.count, by: 256) {
            let chunk = Array(ids[start..<min(start + 256, ids.count)])
            let body: [String: Any] = ["op": "feed.read", "params": ["items": chunk],
                                       "idempotency_key": UUID().uuidString, "origin": "user"]
            let id = UUID()
            // task-owner: FeedHandoffDriver.running: one feed.read; a failure only leaves the cloud copy unread (U5: nothing queues).
            running[id] = Task { [weak self, owner] in
                do { _ = try await owner("v1/ops", body) } catch { self?.note("read failed: \(Self.describe(error))") }
                self?.running[id] = nil
            }
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// A daemon refusal about one item (it moved, vanished or changed state),
    /// as opposed to a lost connection.
    nonisolated static func isItemRefusal(_ error: any Error) -> Bool {
        guard case let DaemonError.command(_, _, code, _, _) = error else { return false }
        return ["feed.invalid_state", "feed.moving", "not_found", "owner.unreachable"].contains(code ?? "")
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if case let FeedServiceError.owner(code, _) = error { return code }
        if case let DaemonError.command(_, _, code?, _, _) = error { return code }
        return String(describing: error).prefix(120).description
    }
}
