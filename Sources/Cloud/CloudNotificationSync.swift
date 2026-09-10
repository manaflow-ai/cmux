import Combine
import Foundation

// Cloud notifications: the VM's cmux-tui daemon is the source of truth.
//
// A machine's notifications arrive as rows of the `notifications` collection
// on the same cursor-resumable state feed the Cloud tree already consumes, so
// a notification posted while the link was down reaches this Mac through the
// feed's ordinary catch-up. Read state is per client: each row carries
// `read_by`, and this Mac acknowledges with `notification.ack` under its own
// durable client id. Nothing here runs a listener, a timer, or a second
// stream; every step is driven by an accepted snapshot or delta, a link
// reconnect, or a local read.

/// One row of the daemon's `notifications` collection.
struct CloudVMNotificationRow: Hashable, Sendable {
    var id: String
    var title: String
    /// `cmux notify --subtitle` inside the machine; nil when the producer gave none.
    var subtitle: String?
    var body: String
    var level: String
    var createdAtMs: UInt64
    var terminalID: String?
    var readBy: [String]

    func isRead(by clientID: String) -> Bool {
        readBy.contains(clientID)
    }

    /// Rows of the accepted state, oldest first. The document keeps the
    /// collection verbatim even though the typed graph does not model it, so
    /// this never re-parses the whole snapshot.
    static func rows(from state: CloudVMState) -> [CloudVMNotificationRow] {
        state.otherEntities
            .filter { $0.kind == "notifications" }
            .compactMap { row(fromPayload: $0.payload) }
            .sorted { lhs, rhs in
                if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                return lhs.id < rhs.id
            }
    }

    static func row(fromPayload payload: Data) -> CloudVMNotificationRow? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return row(fromObject: object)
    }

    static func row(fromObject object: [String: Any]) -> CloudVMNotificationRow? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let title = object["title"] as? String else { return nil }
        let createdAtMs: UInt64
        if let string = object["created_at_ms"] as? String, let value = UInt64(string) {
            createdAtMs = value
        } else if let number = object["created_at_ms"] as? NSNumber, number.int64Value >= 0 {
            createdAtMs = number.uint64Value
        } else {
            createdAtMs = 0
        }
        let readBy = (object["read_by"] as? [Any])?.compactMap { $0 as? String } ?? []
        return CloudVMNotificationRow(
            id: id,
            title: title,
            subtitle: (object["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            body: object["body"] as? String ?? "",
            level: object["level"] as? String ?? "info",
            createdAtMs: createdAtMs,
            terminalID: (object["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            readBy: readBy
        )
    }
}

/// Durable per-machine sync state. `delivered` remembers which retained rows
/// this Mac already turned into local notifications, so a snapshot repair, a
/// reconnect replay, or an app relaunch never re-delivers one. `pendingAcks`
/// are reads the daemon has not confirmed yet; each batch keeps its
/// idempotency key across retries so a retried ack replays instead of
/// committing twice.
struct CloudNotificationSyncState: Codable, Equatable, Sendable {
    struct PendingAck: Codable, Equatable, Sendable {
        var key: String
        var ids: [String]
    }

    static let deliveredLimit = 512

    var delivered: [String] = []
    var pendingAcks: [PendingAck] = []

    var pendingIDs: Set<String> {
        Set(pendingAcks.flatMap(\.ids))
    }
}

/// Pure transitions over `CloudNotificationSyncState`. Every effect the sync
/// performs is decided here and only here, so the fault-injection tests cover
/// the same code the app runs.
enum CloudNotificationSyncReducer {
    struct Plan: Equatable {
        var deliver: [CloudVMNotificationRow]
        /// Ids this Mac delivered that the daemon no longer retains, whether a
        /// `notification.clear` removed them or the ledger evicted them. The
        /// local banner is withdrawn in both cases: the machine is the source
        /// of truth and it no longer has the row.
        var removed: [String]
        var state: CloudNotificationSyncState
    }

    /// Fold one accepted set of rows. A row is delivered when this client has
    /// not read it, has not delivered it, and is not already acknowledging it.
    /// Bookkeeping for rows the ledger evicted is dropped in the same step.
    static func plan(
        rows: [CloudVMNotificationRow],
        clientID: String,
        state: CloudNotificationSyncState
    ) -> Plan {
        let retained = Set(rows.map(\.id))
        var next = state
        let removed = next.delivered.filter { !retained.contains($0) }
        next.delivered.removeAll { !retained.contains($0) }
        // Pending acks are never pruned here: the daemon answers an evicted
        // id with `unknown`, which completes the batch, and dropping a batch
        // locally would lose a read that was recorded before the rows arrived.
        let delivered = Set(next.delivered)
        let pending = next.pendingIDs
        var deliver: [CloudVMNotificationRow] = []
        for row in rows where !row.isRead(by: clientID) && !delivered.contains(row.id) && !pending.contains(row.id) {
            deliver.append(row)
            next.delivered.append(row.id)
        }
        if next.delivered.count > CloudNotificationSyncState.deliveredLimit {
            next.delivered.removeFirst(next.delivered.count - CloudNotificationSyncState.deliveredLimit)
        }
        return Plan(deliver: deliver, removed: removed, state: next)
    }

    /// Record local reads. Ids already pending, or whose row is known to be
    /// read by this client, are skipped; every other id forms a new batch,
    /// including ids whose rows have not arrived yet (a read after launch
    /// before the first snapshot). The daemon reports ids it no longer
    /// retains as `unknown`, which completes the batch. The batch key is
    /// minted once and survives retries.
    static func recordRead(
        ids: [String],
        rows: [CloudVMNotificationRow],
        clientID: String,
        state: CloudNotificationSyncState,
        newKey: () -> String
    ) -> CloudNotificationSyncState {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = state.pendingIDs
        var batch: [String] = []
        for id in ids where !batch.contains(id) {
            if pending.contains(id) { continue }
            if let row = byID[id], row.isRead(by: clientID) { continue }
            batch.append(id)
        }
        guard !batch.isEmpty else { return state }
        var next = state
        next.pendingAcks.append(CloudNotificationSyncState.PendingAck(key: newKey(), ids: batch))
        return next
    }

    static func ackCompleted(key: String, state: CloudNotificationSyncState) -> CloudNotificationSyncState {
        var next = state
        next.pendingAcks.removeAll { $0.key == key }
        return next
    }

    /// Read-your-write overlay: after the daemon confirmed a batch, the rows
    /// it named carry this client until the feed delivers the same fact, so
    /// the unread set cannot flicker back between the ack and its delta.
    static func markingRead(
        ids: [String],
        clientID: String,
        rows: [CloudVMNotificationRow]
    ) -> [CloudVMNotificationRow] {
        let acked = Set(ids)
        return rows.map { row in
            guard acked.contains(row.id), !row.readBy.contains(clientID) else { return row }
            var row = row
            row.readBy.append(clientID)
            row.readBy.sort()
            return row
        }
    }

    /// Terminals with a notification this client has neither read nor
    /// acknowledged, for the Cloud tree's attention dot.
    static func unreadTerminalIDs(
        rows: [CloudVMNotificationRow],
        clientID: String,
        state: CloudNotificationSyncState
    ) -> Set<String> {
        let pending = state.pendingIDs
        var result = Set<String>()
        for row in rows where !row.isRead(by: clientID) && !pending.contains(row.id) {
            if let terminalID = row.terminalID { result.insert(terminalID) }
        }
        return result
    }
}

/// Correlation keys tie a local `TerminalNotification` back to its machine
/// and daemon row, so a local read can be acknowledged and a re-delivery
/// replaces its own prior banner only.
enum CloudNotificationCorrelation {
    static let prefix = "cloud-notification:"

    static func key(machineID: String, notificationID: String) -> String {
        "\(prefix)\(machineID):\(notificationID)"
    }

    static func parse(_ key: String) -> (machineID: String, notificationID: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let separator = rest.lastIndex(of: ":") else { return nil }
        let machineID = String(rest[..<separator])
        let notificationID = String(rest[rest.index(after: separator)...])
        guard !machineID.isEmpty, !notificationID.isEmpty else { return nil }
        return (machineID, notificationID)
    }
}

/// Durable JSON state in `UserDefaults`, one key per machine. Not actor-bound:
/// `UserDefaults` is thread-safe and the sync calls it from the main actor.
struct CloudNotificationSyncStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(machineID: String) -> String {
        "cloud.notifications.sync.\(machineID)"
    }

    func load(machineID: String) -> CloudNotificationSyncState {
        guard let data = defaults.data(forKey: Self.key(machineID: machineID)),
              let state = try? JSONDecoder().decode(CloudNotificationSyncState.self, from: data) else {
            return CloudNotificationSyncState()
        }
        return state
    }

    func save(_ state: CloudNotificationSyncState, machineID: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key(machineID: machineID))
    }

    func remove(machineID: String) {
        defaults.removeObject(forKey: Self.key(machineID: machineID))
    }
}

/// Where a daemon notification lands locally: the workspace bound to the
/// machine, and the pane showing the terminal when one is open here.
struct CloudNotificationDeliveryTarget: Equatable, Sendable {
    var workspaceID: UUID
    var panelID: UUID?
}

/// One machine's notification sync. Owned by that machine's surface provider,
/// which feeds it every accepted state and reports link reconnects. All
/// effects go through the injected closures so tests drive it without a
/// daemon: `deliver` creates the local notification, `send` performs one
/// `notification.ack` round trip over the link.
@MainActor
final class CloudNotificationSync {
    /// Returns false when the store declined the notification (muted
    /// workspace, no store); the row then stays undelivered for a later fold.
    typealias Deliverer = @MainActor (CloudVMNotificationRow, CloudNotificationDeliveryTarget) -> Bool
    typealias TargetResolver = @MainActor (CloudVMNotificationRow) -> CloudNotificationDeliveryTarget?
    typealias AckSender = @MainActor (CloudNotificationSyncState.PendingAck) async throws -> Void
    typealias UnreadObserver = @MainActor (Set<String>) -> Void
    /// Withdraw local banners for rows the machine no longer retains.
    typealias Withdrawer = @MainActor ([String]) -> Void

    let machineID: String
    let clientID: String
    private let store: CloudNotificationSyncStore
    private let deliver: Deliverer
    private let resolveTarget: TargetResolver
    private let send: AckSender
    private let unreadChanged: UnreadObserver
    private let withdraw: Withdrawer
    private let newKey: () -> String

    private(set) var state: CloudNotificationSyncState
    private(set) var rows: [CloudVMNotificationRow] = []
    private(set) var unreadTerminalIDs: Set<String> = []
    /// Rows the target resolver could not place yet (no local workspace for
    /// the machine). They stay undelivered, not consumed, so a later placement
    /// still delivers them once.
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    /// Set by `retire()`: a replaced sync must not write the shared per-machine
    /// key after its provider is gone.
    private var retired = false

    init(
        machineID: String,
        clientID: String,
        store: CloudNotificationSyncStore = CloudNotificationSyncStore(),
        newKey: @escaping () -> String = { "mac-ack-\(UUID().uuidString.lowercased())" },
        resolveTarget: @escaping TargetResolver,
        deliver: @escaping Deliverer,
        send: @escaping AckSender,
        unreadChanged: @escaping UnreadObserver = { _ in },
        withdraw: @escaping Withdrawer = { _ in }
    ) {
        self.machineID = machineID
        self.clientID = clientID
        self.store = store
        self.newKey = newKey
        self.resolveTarget = resolveTarget
        self.deliver = deliver
        self.send = send
        self.unreadChanged = unreadChanged
        self.withdraw = withdraw
        state = store.load(machineID: machineID)
    }

    /// Fold one accepted state. Called after every installed snapshot or
    /// delta; cheap when the rows did not change.
    func apply(rows incoming: [CloudVMNotificationRow]) {
        rows = incoming
        let plan = CloudNotificationSyncReducer.plan(rows: incoming, clientID: clientID, state: state)
        var next = plan.state
        var placed: [(CloudVMNotificationRow, CloudNotificationDeliveryTarget)] = []
        for row in plan.deliver {
            if let target = resolveTarget(row) {
                placed.append((row, target))
            } else {
                // Not consumed: the next fold retries placement.
                next.delivered.removeAll { $0 == row.id }
            }
        }
        // Commit before delivering: the store can call back into this sync
        // while a banner is recorded (a focused surface reads it at once), and
        // that re-entrant commit must build on the state that already counts
        // these rows as delivered.
        commit(next)
        if !plan.removed.isEmpty {
            withdraw(plan.removed)
        }
        var undelivered: [String] = []
        for (row, target) in placed where !deliver(row, target) {
            undelivered.append(row.id)
        }
        if !undelivered.isEmpty {
            var declined = state
            declined.delivered.removeAll { undelivered.contains($0) }
            commit(declined)
        }
        requestFlush()
    }

    /// Local reads of this machine's notifications, by daemon row id.
    func noteRead(notificationIDs: [String]) {
        let next = CloudNotificationSyncReducer.recordRead(
            ids: notificationIDs,
            rows: rows,
            clientID: clientID,
            state: state,
            newKey: newKey
        )
        guard next != state else { return }
        commit(next)
        requestFlush()
    }

    /// The link came back. Anything still pending is retried now.
    func linkDidConnect() {
        requestFlush()
    }

    /// Stop writing on behalf of this machine. A replacement sync for the same
    /// machine loads the durable state itself; this one must not overwrite
    /// it from an in-flight flush.
    func retire() {
        retired = true
        flushTask?.cancel()
        flushTask = nil
    }

    func forget() {
        retire()
        store.remove(machineID: machineID)
    }

    private func commit(_ next: CloudNotificationSyncState) {
        guard !retired else { return }
        state = next
        store.save(next, machineID: machineID)
        let unread = CloudNotificationSyncReducer.unreadTerminalIDs(rows: rows, clientID: clientID, state: next)
        if unread != unreadTerminalIDs {
            unreadTerminalIDs = unread
            unreadChanged(unread)
        }
    }

    /// One in-flight flush at a time, oldest batch first. A failed send stops
    /// the pass and leaves the batch for the next accepted state or reconnect;
    /// there is no timer and no backoff here because the link owns recovery.
    private func requestFlush() {
        guard !state.pendingAcks.isEmpty else { return }
        if flushTask != nil {
            flushRequested = true
            return
        }
        flushTask = Task { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        defer {
            flushTask = nil
            if flushRequested {
                flushRequested = false
                requestFlush()
            }
        }
        while let batch = state.pendingAcks.first {
            if Task.isCancelled { return }
            do {
                try await send(batch)
            } catch {
                return
            }
            if retired { return }
            rows = CloudNotificationSyncReducer.markingRead(ids: batch.ids, clientID: clientID, rows: rows)
            commit(CloudNotificationSyncReducer.ackCompleted(key: batch.key, state: state))
        }
    }
}

extension Notification.Name {
    /// Posted on the main actor after a machine's unread terminal set changes.
    static let cmuxCloudNotificationUnreadDidChange = Notification.Name("cmux.cloudNotifications.unreadDidChange")
}

/// App-wide registry of per-machine syncs. Owns the one subscription on the
/// notification store that turns local reads into acknowledgements, and the
/// unread index the Cloud tree renders.
@MainActor
final class CloudNotificationSyncHub {
    static let shared = CloudNotificationSyncHub()

    private var syncs: [String: CloudNotificationSync] = [:]
    private(set) var unreadTerminalIDs: [String: Set<String>] = [:]
    private var storeSubscription: AnyCancellable?
    private var unreadCloudKeys: Set<String>?

    func register(_ sync: CloudNotificationSync) {
        syncs[sync.machineID] = sync
        observeStoreIfNeeded()
    }

    func unregister(machineID: String) {
        syncs.removeValue(forKey: machineID)
        if unreadTerminalIDs.removeValue(forKey: machineID) != nil {
            NotificationCenter.default.post(name: .cmuxCloudNotificationUnreadDidChange, object: nil)
        }
    }

    func sync(machineID: String) -> CloudNotificationSync? {
        syncs[machineID]
    }

    func setUnread(_ terminalIDs: Set<String>, machineID: String) {
        if terminalIDs.isEmpty {
            guard unreadTerminalIDs.removeValue(forKey: machineID) != nil else { return }
        } else {
            guard unreadTerminalIDs[machineID] != terminalIDs else { return }
            unreadTerminalIDs[machineID] = terminalIDs
        }
        #if DEBUG
        cmuxDebugLog("cloud.notifications.unread machine=\(machineID) terminals=\(terminalIDs.count)")
        #endif
        NotificationCenter.default.post(name: .cmuxCloudNotificationUnreadDidChange, object: nil)
    }

    /// Correlation keys of cloud notifications that were unread in `previous`
    /// and are read or gone in `current`. A dismissal counts as a read: the
    /// person chose not to see it again, on this Mac and on the machine.
    static func newlyReadKeys(previous: Set<String>, current: [TerminalNotification]) -> (read: Set<String>, unread: Set<String>) {
        var unread = Set<String>()
        for notification in current where !notification.isRead {
            if let key = notification.correlationKey, key.hasPrefix(CloudNotificationCorrelation.prefix) {
                unread.insert(key)
            }
        }
        return (previous.subtracting(unread), unread)
    }

    private func observeStoreIfNeeded() {
        guard storeSubscription == nil, let store = AppDelegate.shared?.notificationStore else { return }
        storeSubscription = store.$notifications
            .receive(on: RunLoop.main)
            .sink { [weak self] notifications in
                MainActor.assumeIsolated {
                    self?.storeDidChange(notifications)
                }
            }
    }

    func storeDidChange(_ notifications: [TerminalNotification]) {
        guard let previous = unreadCloudKeys else {
            // First observation seeds the baseline. Rows restored from the
            // durable feed history as already-read never become acks here;
            // the daemon already has them or they were read elsewhere.
            unreadCloudKeys = Self.newlyReadKeys(previous: [], current: notifications).unread
            return
        }
        let (read, unread) = Self.newlyReadKeys(previous: previous, current: notifications)
        unreadCloudKeys = unread
        guard !read.isEmpty else { return }
        var byMachine: [String: [String]] = [:]
        for key in read {
            guard let parsed = CloudNotificationCorrelation.parse(key) else { continue }
            byMachine[parsed.machineID, default: []].append(parsed.notificationID)
        }
        for (machineID, ids) in byMachine {
            syncs[machineID]?.noteRead(notificationIDs: ids)
        }
    }
}
