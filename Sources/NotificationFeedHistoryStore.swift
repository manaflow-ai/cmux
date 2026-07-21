import Foundation

/// Main-actor owner of the durable, chronological notification feed.
@MainActor
final class NotificationFeedHistoryStore {
    nonisolated static let readRetentionLimit = 1_000

    private enum Mutation {
        case record(NotificationFeedHistoryRecord, supersededIDs: Set<UUID>)
        case reconcileActive([NotificationFeedHistoryRecord])
        case markReadIDs(Set<UUID>)
        case markReadWorkspace(UUID)
        case markReadSurface(tabId: UUID, surfaceId: UUID?)
        case markAllRead
        case markUnreadIDs(Set<UUID>)
        case rebindSurface(sourceTabId: UUID, destinationTabId: UUID, surfaceId: UUID)
    }

    private struct MutationResult {
        var changed = false
        var marked = 0
    }

    private(set) var revision = 0
    private(set) var notifications: [NotificationFeedHistoryRecord] = []

    private let readRetentionLimit: Int
    private let persistence: NotificationFeedHistoryPersistence
    private let persistsToDisk: Bool
    private let onChange: (Int) -> Void
    private var didFinishLoading = false
    private var persistenceAllowsWrites = true
    private var pendingMutations: [Mutation] = []
    private var readRecordCount = 0

    private(set) var loadingTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?

    init(
        fileURL: URL?,
        fileManager: FileManager = .default,
        readRetentionLimit: Int = NotificationFeedHistoryStore.readRetentionLimit,
        onChange: @escaping (Int) -> Void = { _ in }
    ) {
        let resolvedReadRetentionLimit = max(0, readRetentionLimit)
        let persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: fileManager,
            readRetentionLimit: resolvedReadRetentionLimit
        )
        self.readRetentionLimit = resolvedReadRetentionLimit
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
                NotificationFeedHistoryRecord(notification: notification),
                supersededIDs: supersededIDs
            )
        )
    }

    /// Idempotently folds the authoritative active-notification state into
    /// durable history. Existing historical rows remain unchanged; only missing
    /// UUIDs are inserted.
    func reconcileActiveNotifications(_ activeNotifications: [TerminalNotification]) {
        guard !activeNotifications.isEmpty else { return }
        _ = commit(
            .reconcileActive(
                activeNotifications.map(NotificationFeedHistoryRecord.init(notification:))
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

    private func commit(_ mutation: Mutation) -> MutationResult {
        if !didFinishLoading {
            pendingMutations.append(mutation)
        }

        let result = Self.apply(
            mutation,
            to: &notifications,
            readRecordCount: &readRecordCount,
            readRetentionLimit: readRetentionLimit
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
            loadedNotifications = snapshot.notifications
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
                readRetentionLimit: readRetentionLimit
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
        let persistedSnapshot = snapshot
        persistenceTask = Task { [persistence] in
            await persistence.persist(persistedSnapshot)
        }
    }

    private static func apply(
        _ mutation: Mutation,
        to records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int,
        readRetentionLimit: Int
    ) -> MutationResult {
        var result = MutationResult()
        switch mutation {
        case .record(let record, let supersededIDs):
            for index in records.indices
            where supersededIDs.contains(records[index].id) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.changed = true
            }
            if insertOrReplace(record, in: &records, readRecordCount: &readRecordCount) {
                result.changed = true
            }

        case .reconcileActive(let activeRecords):
            var knownIDs = Set(records.map(\.id))
            for record in activeRecords where knownIDs.insert(record.id).inserted {
                insert(record, in: &records)
                if record.isRead { readRecordCount += 1 }
                result.changed = true
            }

        case .markReadIDs(let ids):
            for index in records.indices where ids.contains(records[index].id) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0

        case .markReadWorkspace(let tabId):
            for index in records.indices where records[index].tabId == tabId && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0

        case .markReadSurface(let tabId, let surfaceId):
            for index in records.indices
            where records[index].matches(tabId: tabId, surfaceId: surfaceId) && !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0

        case .markAllRead:
            for index in records.indices where !records[index].isRead {
                records[index].isRead = true
                readRecordCount += 1
                result.marked += 1
            }
            result.changed = result.marked > 0

        case .markUnreadIDs(let ids):
            for index in records.indices where ids.contains(records[index].id) && records[index].isRead {
                records[index].isRead = false
                readRecordCount -= 1
                result.marked += 1
            }
            result.changed = result.marked > 0

        case .rebindSurface(let sourceTabId, let destinationTabId, let surfaceId):
            for index in records.indices {
                guard records[index].retargetsToLiveSurfaceOwner,
                      records[index].matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                    continue
                }
                records[index].tabId = destinationTabId
                result.changed = true
            }
        }

        if result.changed {
            trimOldestReadRecords(
                in: &records,
                readRecordCount: &readRecordCount,
                readRetentionLimit: readRetentionLimit
            )
        }
        return result
    }

    private static func insertOrReplace(
        _ record: NotificationFeedHistoryRecord,
        in records: inout [NotificationFeedHistoryRecord],
        readRecordCount: inout Int
    ) -> Bool {
        if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
            let existing = records[existingIndex]
            guard existing != record else { return false }
            records.remove(at: existingIndex)
            if existing.isRead { readRecordCount -= 1 }
        }
        insert(record, in: &records)
        if record.isRead { readRecordCount += 1 }
        return true
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
