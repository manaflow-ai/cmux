import Combine
import Foundation

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
    let persistenceStore: CloudNotificationSyncStore
    private var syncs: [String: CloudNotificationSync] = [:]
    private var notificationGate: CloudMachineNotificationGate

    /// Defaults resolve here rather than as default arguments: the store is
    /// main-actor isolated and cannot be constructed in a default-argument
    /// context.
    init(
        persistenceStore: CloudNotificationSyncStore? = nil,
        gate: CloudMachineNotificationGate = CloudMachineNotificationGate()
    ) {
        self.persistenceStore = persistenceStore ?? CloudNotificationSyncStore()
        notificationGate = gate
    }

    /// One admission budget across all live machine providers.
    func admit(_ row: CloudVMNotificationRow, machineID: String) -> CloudMachineNotificationGate.Decision {
        notificationGate.admit(machineID: machineID, event: CloudMachineNotificationEvent(
            id: row.id, terminalID: row.terminalID, title: row.title, body: row.body
        ))
    }
    private(set) var unreadTerminalIDs: [String: Set<String>] = [:]
    private var storeSubscription: AnyCancellable?
    private weak var store: TerminalNotificationStore?
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
        guard store == nil, let store = AppDelegate.shared?.notificationStore else { return }
        attach(store: store)
    }

    /// Binds the hub to the local store. Local records that become read or
    /// are dismissed acknowledge their rows, and every read or clear the
    /// store applies by target is mirrored onto the rows placed there.
    func attach(store: TerminalNotificationStore) {
        guard self.store !== store else { return }
        self.store = store
        unreadCloudKeys = nil
        storeSubscription = store.$notifications
            .receive(on: RunLoop.main)
            .sink { [weak self] notifications in
                MainActor.assumeIsolated {
                    self?.storeDidChange(notifications)
                }
            }
        store.readTargetObserver = { [weak self] target in
            self?.noteRead(coveredBy: target)
        }
    }

    /// A read the store applied by target (a focused pane, a visited
    /// workspace, mark-all-read, `cmux notify --clear`). Every machine
    /// acknowledges the rows whose current placement the read covers, so the
    /// Cloud tree dot follows the dismissal even for rows that never became a
    /// local record; records for those rows that live on another workspace
    /// (placed there before the terminal was opened here) are read with them.
    func noteRead(coveredBy target: NotificationReadTarget) {
        var readByMachine: [String: Set<String>] = [:]
        for sync in syncs.values {
            let ids = sync.noteRead(coveredBy: target)
            if !ids.isEmpty { readByMachine[sync.machineID] = Set(ids) }
        }
        guard !readByMachine.isEmpty, let store else { return }
        let ids = store.notifications.compactMap { notification -> UUID? in
            guard !notification.isRead, let key = notification.correlationKey,
                  let source = CloudNotificationCorrelation.parse(key),
                  readByMachine[source.machineID]?.contains(source.notificationID) == true else { return nil }
            return notification.id
        }
        guard !ids.isEmpty else { return }
        store.markNotificationFeedRead(ids: Set(ids))
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
            noteRead(notificationIDs: ids, machineID: machineID)
        }
    }

    /// Reads by daemon row id. Without a live sync for the machine (asleep,
    /// feature-suspended, between providers) the read is written to the
    /// durable state directly, so the replacement sync loads it as a pending
    /// acknowledgement instead of restoring the row as unread.
    func noteRead(notificationIDs ids: [String], machineID: String) {
        if let sync = syncs[machineID] {
            sync.noteRead(notificationIDs: ids)
            return
        }
        let state = persistenceStore.load(machineID: machineID)
        // No rows are known here, so the client id (only consulted against a
        // row's `read_by`) does not take part in the decision.
        let next = CloudNotificationSyncReducer.recordRead(
            ids: ids, rows: [], clientID: "", state: state, newKey: CloudNotificationSync.mintAckKey
        )
        guard next != state else { return }
        persistenceStore.save(next, machineID: machineID)
    }
}
