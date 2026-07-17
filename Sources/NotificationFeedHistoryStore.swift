import Foundation

/// Main-actor owner of the durable, chronological notification feed.
@MainActor
final class NotificationFeedHistoryStore {
    static let readRetentionLimit = 1_000

    private(set) var revision: Int
    private(set) var notifications: [NotificationFeedHistoryRecord]

    private let readRetentionLimit: Int
    private let persistence: NotificationFeedHistoryPersistence
    private let persistsToDisk: Bool
    private let onChange: (Int) -> Void
    private var persistenceTask: Task<Void, Never>?
    private var bootstrapActiveNotifications: Bool

    init(
        fileURL: URL?,
        fileManager: FileManager = .default,
        readRetentionLimit: Int = NotificationFeedHistoryStore.readRetentionLimit,
        onChange: @escaping (Int) -> Void = { _ in }
    ) {
        let loaded = NotificationFeedHistoryPersistence.loadSnapshot(
            fileURL: fileURL,
            fileManager: fileManager
        )
        revision = max(0, loaded?.revision ?? 0)
        notifications = loaded?.notifications ?? []
        self.readRetentionLimit = max(0, readRetentionLimit)
        persistence = NotificationFeedHistoryPersistence(
            fileURL: fileURL,
            fileManager: fileManager,
            initialRevision: revision
        )
        persistsToDisk = fileURL != nil
        self.onChange = onChange
        bootstrapActiveNotifications = loaded?.notifications.isEmpty ?? true
        notifications = Self.normalized(
            notifications,
            readRetentionLimit: self.readRetentionLimit
        )
    }

    var snapshot: NotificationFeedHistorySnapshot {
        NotificationFeedHistorySnapshot(
            revision: revision,
            notifications: notifications
        )
    }

    func record(
        _ notification: TerminalNotification,
        supersededIDs: Set<UUID>,
        activeNotificationsForBootstrap: [TerminalNotification]
    ) {
        var updated = notifications
        if bootstrapActiveNotifications {
            Self.mergeMissing(activeNotificationsForBootstrap, into: &updated)
            bootstrapActiveNotifications = false
        }
        for index in updated.indices where supersededIDs.contains(updated[index].id) {
            updated[index].isRead = true
        }
        let record = NotificationFeedHistoryRecord(notification: notification)
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = record
        } else {
            updated.append(record)
        }
        commit(updated)
    }

    func bootstrapIfNeeded(from activeNotifications: [TerminalNotification]) {
        guard bootstrapActiveNotifications, !activeNotifications.isEmpty else { return }
        var updated = notifications
        Self.mergeMissing(activeNotifications, into: &updated)
        bootstrapActiveNotifications = false
        commit(updated)
    }

    @discardableResult
    func markRead(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        var updated = notifications
        var marked = 0
        for index in updated.indices where ids.contains(updated[index].id) && !updated[index].isRead {
            updated[index].isRead = true
            marked += 1
        }
        commit(updated)
        return marked
    }

    @discardableResult
    func markRead(inWorkspace tabId: UUID) -> Int {
        var updated = notifications
        var marked = 0
        for index in updated.indices where updated[index].tabId == tabId && !updated[index].isRead {
            updated[index].isRead = true
            marked += 1
        }
        commit(updated)
        return marked
    }

    @discardableResult
    func markRead(inWorkspace tabId: UUID, surfaceId: UUID?) -> Int {
        var updated = notifications
        var marked = 0
        for index in updated.indices
        where updated[index].matches(tabId: tabId, surfaceId: surfaceId) && !updated[index].isRead {
            updated[index].isRead = true
            marked += 1
        }
        commit(updated)
        return marked
    }

    @discardableResult
    func markAllRead() -> Int {
        var updated = notifications
        var marked = 0
        for index in updated.indices where !updated[index].isRead {
            updated[index].isRead = true
            marked += 1
        }
        commit(updated)
        return marked
    }

    @discardableResult
    func markUnread(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        var updated = notifications
        var marked = 0
        for index in updated.indices where ids.contains(updated[index].id) && updated[index].isRead {
            updated[index].isRead = false
            marked += 1
        }
        commit(updated)
        return marked
    }

    func rebindSurface(
        fromTabId sourceTabId: UUID,
        toTabId destinationTabId: UUID,
        surfaceId: UUID
    ) {
        guard sourceTabId != destinationTabId else { return }
        var updated = notifications
        for index in updated.indices {
            guard updated[index].retargetsToLiveSurfaceOwner,
                  updated[index].matches(tabId: sourceTabId, surfaceId: surfaceId) else {
                continue
            }
            updated[index].tabId = destinationTabId
        }
        commit(updated)
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

    #if DEBUG
    func resetForTesting(bootstrapWith activeNotifications: [TerminalNotification] = []) {
        persistenceTask?.cancel()
        persistenceTask = nil
        revision = 0
        notifications = []
        bootstrapActiveNotifications = true
        if !activeNotifications.isEmpty {
            bootstrapIfNeeded(from: activeNotifications)
        }
    }

    func waitForPersistenceForTesting() async {
        await persistenceTask?.value
    }
    #endif

    private func commit(_ proposed: [NotificationFeedHistoryRecord]) {
        let normalized = Self.normalized(
            proposed,
            readRetentionLimit: readRetentionLimit
        )
        guard normalized != notifications else { return }
        notifications = normalized
        revision += 1
        let persistedSnapshot = snapshot
        if persistsToDisk {
            persistenceTask = Task { [persistence] in
                await persistence.persist(persistedSnapshot)
            }
        }
        onChange(revision)
    }

    private static func mergeMissing(
        _ activeNotifications: [TerminalNotification],
        into records: inout [NotificationFeedHistoryRecord]
    ) {
        var knownIDs = Set(records.map(\.id))
        for notification in activeNotifications where knownIDs.insert(notification.id).inserted {
            records.append(NotificationFeedHistoryRecord(notification: notification))
        }
    }

    private static func normalized(
        _ records: [NotificationFeedHistoryRecord],
        readRetentionLimit: Int
    ) -> [NotificationFeedHistoryRecord] {
        let sorted = records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        var remainingReadSlots = readRetentionLimit
        return sorted.filter { record in
            guard record.isRead else { return true }
            guard remainingReadSlots > 0 else { return false }
            remainingReadSlots -= 1
            return true
        }
    }
}
