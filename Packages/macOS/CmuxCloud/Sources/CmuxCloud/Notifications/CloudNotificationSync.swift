import CmuxSurfaceCatalogModel
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
public struct CloudVMNotificationRow: Hashable, Sendable {
    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        level: String,
        createdAtMs: UInt64,
        terminalID: String? = nil,
        readBy: [String]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.createdAtMs = createdAtMs
        self.terminalID = terminalID
        self.readBy = readBy
    }

    public var id: String
    public var title: String
    /// `cmux notify --subtitle` inside the machine; nil when the producer gave none.
    public var subtitle: String?
    public var body: String
    public var level: String
    public var createdAtMs: UInt64
    public var terminalID: String?
    public var readBy: [String]

    public func isRead(by clientID: String) -> Bool {
        readBy.contains(clientID)
    }

    /// Rows of the accepted state, oldest first. The document keeps the
    /// collection verbatim even though the typed graph does not model it, so
    /// this never re-parses the whole snapshot.
    public static func rows(from state: CloudVMState) -> [CloudVMNotificationRow] {
        state.otherEntities
            .filter { $0.kind == "notifications" }
            .compactMap { row(fromPayload: $0.payload) }
            .sorted { lhs, rhs in
                if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                return lhs.id < rhs.id
            }
    }

    public static func row(fromPayload payload: Data) -> CloudVMNotificationRow? {
        guard payload.count <= CloudMachineNotificationEvent.maxLineBytes,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return row(fromObject: object)
    }

    public static func row(fromObject object: [String: Any]) -> CloudVMNotificationRow? {
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
            title: NotificationTextSanitizer.sanitize(title, maxBytes: CloudMachineNotificationEvent.maxTitleBytes),
            subtitle: (object["subtitle"] as? String).map { NotificationTextSanitizer.sanitize($0, maxBytes: CloudMachineNotificationEvent.maxTitleBytes) }.flatMap { $0.isEmpty ? nil : $0 },
            body: NotificationTextSanitizer.sanitize(object["body"] as? String ?? "", maxBytes: CloudMachineNotificationEvent.maxBodyBytes),
            level: object["level"] as? String ?? "info",
            createdAtMs: createdAtMs,
            terminalID: (object["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            readBy: readBy
        )
    }
}

/// Pure transitions over `CloudNotificationSyncState`. Every effect the sync
/// performs is decided here and only here, so the fault-injection tests cover
/// the same code the app runs.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudNotificationSyncReducer: Sendable {
    public struct Plan: Equatable, Sendable {
        public var deliver: [CloudVMNotificationRow]
        /// Ids this Mac delivered that the daemon no longer retains, whether a
        /// `notification.clear` removed them or the ledger evicted them. The
        /// local banner is withdrawn in both cases: the machine is the source
        /// of truth and it no longer has the row.
        public var removed: [String]
        public var state: CloudNotificationSyncState
    }

    /// Fold one accepted set of rows. A row is delivered when this client has
    /// not read it, has not delivered it, and is not already acknowledging it.
    /// Bookkeeping for rows the ledger evicted is dropped in the same step.
    public static func plan(
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
        var read = next.readIDs
        var deliver: [CloudVMNotificationRow] = []
        for row in rows {
            if row.isRead(by: clientID) {
                appendReadID(row.id, to: &next, ids: &read)
                continue
            }
            guard !read.contains(row.id),
                  !delivered.contains(row.id),
                  !pending.contains(row.id) else { continue }
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
    public static func recordRead(
        ids: [String],
        rows: [CloudVMNotificationRow],
        clientID: String,
        state: CloudNotificationSyncState,
        newKey: () -> String
    ) -> CloudNotificationSyncState {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = state.pendingIDs
        let read = state.readIDs
        var batch: [String] = []
        for id in ids where !batch.contains(id) {
            if pending.contains(id) { continue }
            if read.contains(id) { continue }
            if let row = byID[id], row.isRead(by: clientID) { continue }
            batch.append(id)
        }
        guard !batch.isEmpty else { return state }
        var next = state
        next.pendingAcks.append(CloudNotificationSyncState.PendingAck(key: newKey(), ids: batch))
        return next
    }

    public static func ackCompleted(key: String, state: CloudNotificationSyncState) -> CloudNotificationSyncState {
        var next = state
        var acknowledged: [String] = []
        var remaining: [CloudNotificationSyncState.PendingAck] = []
        for batch in next.pendingAcks {
            if batch.key == key {
                acknowledged.append(contentsOf: batch.ids)
            } else {
                remaining.append(batch)
            }
        }
        guard !acknowledged.isEmpty else { return state }
        next.pendingAcks = remaining
        var read = next.readIDs
        for id in acknowledged {
            appendReadID(id, to: &next, ids: &read)
        }
        return next
    }

    private static func appendReadID(
        _ id: String,
        to state: inout CloudNotificationSyncState,
        ids: inout Set<String>
    ) {
        guard ids.insert(id).inserted else { return }
        if state.read.count >= CloudNotificationSyncState.deliveredLimit,
           let evicted = state.read.first {
            state.read.removeFirst()
            ids.remove(evicted)
        }
        state.read.append(id)
    }

    /// Read-your-write overlay: after the daemon confirmed a batch, the rows
    /// it named carry this client until the feed delivers the same fact, so
    /// the unread set cannot flicker back between the ack and its delta.
    public static func markingRead(
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
    public static func unreadTerminalIDs(
        rows: [CloudVMNotificationRow],
        clientID: String,
        state: CloudNotificationSyncState
    ) -> Set<String> {
        let pending = state.pendingIDs
        let read = state.readIDs
        var result = Set<String>()
        for row in rows where !row.isRead(by: clientID)
            && !read.contains(row.id)
            && !pending.contains(row.id) {
            if let terminalID = row.terminalID { result.insert(terminalID) }
        }
        return result
    }
}

/// Where a daemon notification lands locally: the workspace bound to the
/// machine, and the pane showing the terminal when one is open here.
public struct CloudNotificationDeliveryTarget: Equatable, Sendable {
    public init(
        workspaceID: UUID,
        panelID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }

    public var workspaceID: UUID
    public var panelID: UUID?
}

/// One machine's notification sync. Owned by that machine's surface provider,
/// which feeds it every accepted state and reports link reconnects. All
/// effects go through the injected closures so tests drive it without a
/// daemon: `deliver` creates the local notification, `send` performs one
/// `notification.ack` round trip over the link.
@MainActor
public final class CloudNotificationSync {
    /// A declined row stays undelivered for a later fold; a suppressed row is
    /// consumed and read in the same fold (see `CloudNotificationDeliveryOutcome`).
    public typealias Deliverer = @MainActor (CloudVMNotificationRow, CloudNotificationDeliveryTarget) -> CloudNotificationDeliveryOutcome
    public typealias TargetResolver = @MainActor (CloudVMNotificationRow) -> CloudNotificationDeliveryTarget?
    public typealias AckSender = @MainActor (CloudNotificationSyncState.PendingAck) async throws -> Void
    public typealias UnreadObserver = @MainActor (Set<String>) -> Void
    /// Withdraw local banners for rows the machine no longer retains.
    public typealias Withdrawer = @MainActor ([String]) -> Void

    public let machineID: String
    public let clientID: String
    private let store: CloudNotificationSyncStore
    private let deliver: Deliverer
    private let resolveTarget: TargetResolver
    private let send: AckSender
    private let unreadChanged: UnreadObserver
    private let withdraw: Withdrawer
    private let newKey: () -> String

    public private(set) var state: CloudNotificationSyncState
    public private(set) var rows: [CloudVMNotificationRow] = []
    public private(set) var unreadTerminalIDs: Set<String> = []
    private var hasAppliedSnapshot = false
    /// Rows whose delivery was transiently declined or had no local placement.
    /// A catalog change or later feed fold retries only this small set instead
    /// of refolding every unchanged row.
    private var retryableDeliveryIDs: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    /// Set by `retire()`: a replaced sync must not write the shared per-machine
    /// key after its provider is gone.
    private var retired = false

    /// The idempotency key of one `notification.ack` batch.
    public nonisolated static func mintAckKey() -> String {
        "mac-ack-\(UUID().uuidString.lowercased())"
    }

    public init(
        machineID: String,
        clientID: String,
        store: CloudNotificationSyncStore,
        newKey: @escaping () -> String = CloudNotificationSync.mintAckKey,
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
    @discardableResult
    public func apply(rows incoming: [CloudVMNotificationRow]) -> Bool {
        guard !retired else { return false }
        guard rows != incoming || !retryableDeliveryIDs.isEmpty || !hasAppliedSnapshot else {
            requestFlush()
            return false
        }
        hasAppliedSnapshot = true
        rows = incoming
        let plan = CloudNotificationSyncReducer.plan(rows: incoming, clientID: clientID, state: state)
        var next = plan.state
        var placed: [(CloudVMNotificationRow, CloudNotificationDeliveryTarget)] = []
        retryableDeliveryIDs.removeAll(keepingCapacity: true)
        for row in plan.deliver {
            if let target = resolveTarget(row) {
                placed.append((row, target))
            } else {
                // Not consumed: the next fold retries placement.
                next.delivered.removeAll { $0 == row.id }
                retryableDeliveryIDs.insert(row.id)
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
        var suppressed: [String] = []
        for (row, target) in placed {
            switch deliver(row, target) {
            case .delivered:
                break
            case .declined:
                undelivered.append(row.id)
                retryableDeliveryIDs.insert(row.id)
            case .suppressed:
                suppressed.append(row.id)
            }
        }
        if !undelivered.isEmpty || !suppressed.isEmpty {
            // Built on the current state, not `next`: a delivery can re-enter
            // through the store and commit in between.
            var declined = state
            declined.delivered.removeAll { undelivered.contains($0) }
            if !suppressed.isEmpty {
                declined = CloudNotificationSyncReducer.recordRead(
                    ids: suppressed, rows: rows, clientID: clientID, state: declined, newKey: newKey
                )
            }
            commit(declined)
        }
        requestFlush()
        return true
    }

    /// Local reads of this machine's notifications, by daemon row id.
    public func noteRead(notificationIDs: [String]) {
        guard !retired else { return }
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

    /// Local reads by target: every unread row whose current placement the
    /// read covers is acknowledged, whether or not it ever became a local
    /// record (an admission drop, a row placed elsewhere before the terminal
    /// was opened here). Returns the ids so the caller can mirror the read
    /// onto local records that live on another workspace.
    @discardableResult
    public func noteRead(coveredBy target: NotificationReadTarget) -> [String] {
        guard !retired else { return [] }
        let pending = state.pendingIDs
        let read = state.readIDs
        var ids: [String] = []
        for row in rows where !row.isRead(by: clientID) && !read.contains(row.id) && !pending.contains(row.id) {
            if case .all = target {
                ids.append(row.id)
            } else if let placement = resolveTarget(row), placement.isCovered(by: target) {
                ids.append(row.id)
            }
        }
        guard !ids.isEmpty else { return [] }
        noteRead(notificationIDs: ids)
        return ids
    }

    /// The link came back. Anything still pending is retried now.
    public func linkDidConnect() {
        guard !retired else { return }
        requestFlush()
    }

    /// Attempts outstanding reads and joins that pass, including persistence.
    /// Failed sends remain pending for the next reconnect or accepted state.
    public func flushPendingReads() async {
        requestFlush()
        while let flushTask { await flushTask.value }
        await store.flush()
    }

    /// Stop writing on behalf of this machine. A replacement sync for the same
    /// machine loads the durable state itself; this one must not overwrite
    /// it from an in-flight flush.
    public func retire() {
        retired = true
        flushTask?.cancel()
        flushTask = nil
    }

    public func forget() {
        retire()
        store.remove(machineID: machineID)
    }

    private func commit(_ next: CloudNotificationSyncState) {
        guard !retired else { return }
        if next != state {
            state = next
            store.save(next, machineID: machineID)
        }
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
        guard !retired, !state.pendingAcks.isEmpty else { return }
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
                await store.flush()
                guard !retired, !Task.isCancelled else { return }
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
