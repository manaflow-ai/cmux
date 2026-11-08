import Foundation

/// Main-actor owner of the durable, chronological notification feed.
@MainActor
final class NotificationFeedHistoryStore {
    nonisolated static let readRetentionLimit = 1_000
    nonisolated static let totalRetentionLimit = 2_000

    private(set) var revision = 0
    private(set) var notifications: [NotificationFeedHistoryRecord] = []

    private let readRetentionLimit: Int
    private let totalRetentionLimit: Int
    private let persistence: NotificationFeedHistoryPersistence
    private let persistsToDisk: Bool
    private let onChange: (Int) -> Void
    private var didFinishLoading = false
    private var persistenceAllowsWrites = true
    private var pendingMutations: [NotificationFeedHistoryMutation] = []
    private var readRecordCount = 0

    private(set) var loadingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var pendingPersistenceSnapshot: NotificationFeedHistorySnapshot?

    init(
        fileURL: URL?,
        fileManager: FileManager = .default,
        readRetentionLimit: Int = NotificationFeedHistoryStore.readRetentionLimit,
        totalRetentionLimit: Int = NotificationFeedHistoryStore.totalRetentionLimit,
        onChange: @escaping (Int) -> Void = { _ in }
    ) {
        let resolvedReadRetentionLimit = max(0, readRetentionLimit)
        let resolvedTotalRetentionLimit = max(0, totalRetentionLimit)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: fileManager,
            readRetentionLimit: resolvedReadRetentionLimit,
            totalRetentionLimit: resolvedTotalRetentionLimit
        )
        self.readRetentionLimit = resolvedReadRetentionLimit
        self.totalRetentionLimit = resolvedTotalRetentionLimit
        self.persistence = persistence
        persistsToDisk = fileURL != nil
        self.onChange = onChange

        loadingTask = Task { [weak self, persistence] in
            let outcome = await persistence.load()
            guard !Task.isCancelled else { return }
            self?.finishLoading(outcome)
        }
    }

    var snapshot: NotificationFeedHistorySnapshot {
        NotificationFeedHistorySnapshot(
            revision: revision,
            notifications: notifications
        )
    }

    func record(
        _ notification: TerminalNotification,
        supersededIDs: Set<UUID>
    ) {
        _ = commit(
            .record(
                NotificationFeedHistoryRecord(notification: notification).boundedForHistory(),
                supersededIDs: supersededIDs
            )
        )
    }

    /// Idempotently folds the authoritative active-notification state into
    /// durable history. Existing historical rows remain unchanged; only missing
    /// UUIDs are inserted.
    func reconcileActiveNotifications(_ activeNotifications: [TerminalNotification]) {
        let activeNotifications = Self.retainableActiveNotifications(
            activeNotifications,
            totalRetentionLimit: totalRetentionLimit
        )
        guard !activeNotifications.isEmpty else { return }
        _ = commit(
            .reconcileActive(
                activeNotifications.map {
                    NotificationFeedHistoryRecord(notification: $0).boundedForHistory()
                }
            )
        )
    }

    @discardableResult
    func markRead(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        return commit(.markReadIDs(ids)).marked
    }

    @discardableResult
    func markRead(inWorkspace tabId: UUID) -> Int {
        commit(.markReadWorkspace(tabId)).marked
    }

    @discardableResult
    func markRead(inWorkspace tabId: UUID, surfaceId: UUID?) -> Int {
        commit(.markReadSurface(tabId: tabId, surfaceId: surfaceId)).marked
    }

    @discardableResult
    func markAllRead() -> Int {
        commit(.markAllRead).marked
    }

    @discardableResult
    func markUnread(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        return commit(.markUnreadIDs(ids)).marked
    }

    func rebindSurface(
        fromTabId sourceTabId: UUID,
        toTabId destinationTabId: UUID,
        surfaceId: UUID
    ) {
        guard sourceTabId != destinationTabId else { return }
        _ = commit(
            .rebindSurface(
                sourceTabId: sourceTabId,
                destinationTabId: destinationTabId,
                surfaceId: surfaceId
            )
        )
    }

    static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID = bundleID?.isEmpty == false ? bundleID! : "com.cmuxterm.app"
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(
                "notification-feed-history-\(safeBundleID).json",
                isDirectory: false
            )
    }

    private func commit(_ mutation: NotificationFeedHistoryMutation) -> NotificationFeedHistoryMutationResult {
        if !didFinishLoading {
            pendingMutations.append(mutation)
        }

        let result = Self.apply(
            mutation,
            to: &notifications,
            readRecordCount: &readRecordCount,
            readRetentionLimit: readRetentionLimit,
            totalRetentionLimit: totalRetentionLimit
        )
        guard result.changed else { return result }

        revision += 1
        if didFinishLoading {
            schedulePersistence()
        }
        onChange(revision)
        return result
    }

    private func finishLoading(_ outcome: NotificationFeedHistoryLoadOutcome) {
        guard !didFinishLoading else { return }
        let previousSnapshot = snapshot

        var loadedRevision: Int
        var loadedNotifications: [NotificationFeedHistoryRecord]
        switch outcome {
        case .loaded(let snapshot):
            loadedRevision = snapshot.revision
            loadedNotifications = snapshot.notifications.map { $0.boundedForHistory() }
        case .missing, .corrupt:
            loadedRevision = 0
            loadedNotifications = []
        case .unsupportedVersion:
            loadedRevision = 0
            loadedNotifications = []
            persistenceAllowsWrites = false
        }

        var loadedReadRecordCount = loadedNotifications.lazy.filter(\.isRead).count
        var replayedChanges = 0
        for mutation in pendingMutations {
            let result = Self.apply(
                mutation,
                to: &loadedNotifications,
                readRecordCount: &loadedReadRecordCount,
                readRetentionLimit: readRetentionLimit,
                totalRetentionLimit: totalRetentionLimit
            )
            if result.changed {
                replayedChanges += 1
            }
        }
        pendingMutations.removeAll(keepingCapacity: false)

        let persistedRevision = loadedRevision
        loadedRevision += replayedChanges
        revision = max(revision, loadedRevision)
        notifications = loadedNotifications
        readRecordCount = loadedReadRecordCount
        didFinishLoading = true

        if persistenceAllowsWrites,
           revision > persistedRevision,
           (replayedChanges > 0 || revision != loadedRevision) {
            schedulePersistence()
        }
        if snapshot != previousSnapshot {
            onChange(revision)
        }
    }

    private func schedulePersistence() {
        guard persistsToDisk, persistenceAllowsWrites else { return }
        pendingPersistenceSnapshot = snapshot
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self, persistence] in
            while !Task.isCancelled {
                guard let snapshot = self?.consumePendingPersistenceSnapshot() else {
                    break
                }
                await persistence.persist(snapshot)
            }
            self?.finishPersistenceTask()
        }
    }

    private func consumePendingPersistenceSnapshot() -> NotificationFeedHistorySnapshot? {
        let snapshot = pendingPersistenceSnapshot
        pendingPersistenceSnapshot = nil
        return snapshot
    }

    private func finishPersistenceTask() {
        persistenceTask = nil
        if pendingPersistenceSnapshot != nil {
            schedulePersistence()
        }
    }

    private static func apply(
        _ mutation: NotificationFeedHistoryMutation,
        to records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int,
        readRetentionLimit: Int,
        totalRetentionLimit: Int
    ) -> NotificationFeedHistoryMutationResult {
        var result = NotificationFeedHistoryMutationResult()
        var insertedNewIDs = Set<UUID>()
        var changedExistingState = false
        switch mutation {
        case .record(let record, let supersededIDs):
            let record = record.boundedForHistory()
            for index in records.indices
            where supersededIDs.contains(records[index].id) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.changed = true
                changedExistingState = true
            }
            switch insertOrReplace(record, in: &records, readRecordCount: &readRecordCount) {
            case .none:
                break
            case .insertedNew(let id):
                insertedNewIDs.insert(id)
                result.changed = true
            case .replacedExisting:
                changedExistingState = true
                result.changed = true
            }

        case .reconcileActive(let activeRecords):
            var knownIDs = Set(records.map(\.id))
            for record in retainableActiveRecords(
                activeRecords,
                totalRetentionLimit: totalRetentionLimit
            ) where knownIDs.insert(record.id).inserted {
                insert(record, in: &records)
                if record.isRead { readRecordCount += 1 }
                insertedNewIDs.insert(record.id)
                result.changed = true
            }

        case .markReadIDs(let ids):
            for index in records.indices where ids.contains(records[index].id) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0
            changedExistingState = result.changed

        case .markReadWorkspace(let tabId):
            for index in records.indices where records[index].tabId == tabId && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0
            changedExistingState = result.changed

        case .markReadSurface(let tabId, let surfaceId):
            for index in records.indices
            where records[index].matches(tabId: tabId, surfaceId: surfaceId) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0
            changedExistingState = result.changed

        case .markAllRead:
            for index in records.indices where !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0
            changedExistingState = result.changed

        case .markUnreadIDs(let ids):
            for index in records.indices where ids.contains(records[index].id) && records[index].isRead {
                records[index].isRead = false
                readRecordCount -= 1
                result.marked += 1
            }
            result.changed = result.marked > 0
            changedExistingState = result.changed

        case .rebindSurface(let sourceTabId, let destinationTabId, let surfaceId):
            for index in records.indices {
                guard records[index].retargetsToLiveSurfaceOwner,
                      records[index].matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                    continue
                }
                records[index].tabId = destinationTabId
                result.changed = true
                changedExistingState = true
            }
        }

        if result.changed {
            trimOldestReadRecords(
                in: &records,
                readRecordCount: &readRecordCount,
                readRetentionLimit: readRetentionLimit
            )
            trimOldestRecords(
                in: &records,
                readRecordCount: &readRecordCount,
                totalRetentionLimit: totalRetentionLimit
            )
            if !changedExistingState,
               !insertedNewIDs.isEmpty,
               !records.contains(where: { insertedNewIDs.contains($0.id) }) {
                result.changed = false
            }
        }
        return result
    }

    private static func retainableActiveNotifications(
        _ notifications: [TerminalNotification],
        totalRetentionLimit: Int
    ) -> [TerminalNotification] {
        guard totalRetentionLimit > 0 else { return [] }
        guard notifications.count > totalRetentionLimit else { return notifications }
        var heap = NotificationFeedHistoryRetainedActiveNotificationHeap(limit: totalRetentionLimit)
        for notification in notifications {
            heap.insert(notification)
        }
        return heap.sortedNewestFirst()
    }

    private static func retainableActiveRecords(
        _ records: [NotificationFeedHistoryRecord],
        totalRetentionLimit: Int
    ) -> [NotificationFeedHistoryRecord] {
        guard totalRetentionLimit > 0 else { return [] }
        guard records.count > totalRetentionLimit else { return records }
        return Array(records.sorted(by: recordPrecedes).prefix(totalRetentionLimit))
    }

    private static func insertOrReplace(
        _ record: NotificationFeedHistoryRecord,
        in records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int
    ) -> NotificationFeedHistoryInsertionChange {
        if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
            let existing = records[existingIndex]
            guard existing != record else { return .none }
            records.remove(at: existingIndex)
            if existing.isRead { readRecordCount -= 1 }
            insert(record, in: &records)
            if record.isRead { readRecordCount += 1 }
            return .replacedExisting
        }
        insert(record, in: &records)
        if record.isRead { readRecordCount += 1 }
        return .insertedNew(record.id)
    }

    private static func insert(
        _ record: NotificationFeedHistoryRecord,
        in records: inout [NotificationFeedHistoryRecord]
    ) {
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if recordPrecedes(records[middle], record) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        records.insert(record, at: lowerBound)
    }

    private static func trimOldestReadRecords(
        in records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int,
        readRetentionLimit: Int
    ) {
        var index = records.count
        while readRecordCount > readRetentionLimit, index > 0 {
            index -= 1
            guard records[index].isRead else { continue }
            records.remove(at: index)
            readRecordCount -= 1
        }
    }

    private static func trimOldestRecords(
        in records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int,
        totalRetentionLimit: Int
    ) {
        while records.count > totalRetentionLimit {
            let removed = records.removeLast()
            if removed.isRead {
                readRecordCount -= 1
            }
        }
    }

    private static func recordPrecedes(
        _ lhs: NotificationFeedHistoryRecord,
        _ rhs: NotificationFeedHistoryRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

}
