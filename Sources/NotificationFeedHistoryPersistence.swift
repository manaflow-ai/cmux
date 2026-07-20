import Foundation
import os

nonisolated private let notificationFeedPersistenceLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-feed-persistence"
)

/// The durable feed's startup state. Unsupported snapshots remain intact and
/// put persistence into a read-only mode until this version of cmux exits.
nonisolated enum NotificationFeedHistoryLoadOutcome: Equatable, Sendable {
    case missing
    case loaded(NotificationFeedHistorySnapshot)
    case corrupt
    case unsupportedVersion(Int)
}

/// Owns all notification-feed disk access, including the initial read, so JSON
/// work never runs on the main actor. Writes are serialized and stale revisions
/// are rejected.
actor NotificationFeedHistoryPersistence {
    private let fileURL: URL?
    private let fileManager: FileManager
    private let readRetentionLimit: Int
    private var lastPersistedRevision = 0
    private var loadOutcome: NotificationFeedHistoryLoadOutcome?
    private var allowsWrites = true

    init(
        fileURL: URL?,
        fileManager: FileManager,
        readRetentionLimit: Int = NotificationFeedHistoryStore.readRetentionLimit
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.readRetentionLimit = max(0, readRetentionLimit)
    }

    func load() -> NotificationFeedHistoryLoadOutcome {
        if let loadOutcome { return loadOutcome }
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else {
            let outcome = NotificationFeedHistoryLoadOutcome.missing
            loadOutcome = outcome
            return outcome
        }

        let outcome: NotificationFeedHistoryLoadOutcome
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(NotificationFeedHistorySnapshot.self, from: data)
            guard decoded.version == NotificationFeedHistorySnapshot.currentVersion else {
                allowsWrites = false
                outcome = .unsupportedVersion(decoded.version)
                loadOutcome = outcome
                return outcome
            }
            let snapshot = NotificationFeedHistorySnapshot(
                revision: max(0, decoded.revision),
                notifications: Self.normalized(
                    decoded.notifications,
                    readRetentionLimit: readRetentionLimit
                )
            )
            lastPersistedRevision = snapshot.revision
            outcome = .loaded(snapshot)
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed load failed file=\(fileURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            outcome = .corrupt
        }
        loadOutcome = outcome
        return outcome
    }

    func persist(_ snapshot: NotificationFeedHistorySnapshot) {
        _ = load()
        guard allowsWrites,
              snapshot.version == NotificationFeedHistorySnapshot.currentVersion,
              snapshot.revision > lastPersistedRevision else {
            return
        }
        guard let fileURL else {
            lastPersistedRevision = snapshot.revision
            loadOutcome = .loaded(snapshot)
            return
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            lastPersistedRevision = snapshot.revision
            loadOutcome = .loaded(snapshot)
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed persist failed file=\(fileURL.path, privacy: .private) revision=\(snapshot.revision) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func normalized(
        _ records: [NotificationFeedHistoryRecord],
        readRetentionLimit: Int
    ) -> [NotificationFeedHistoryRecord] {
        let sorted = records.sorted(by: recordPrecedes)
        var remainingReadSlots = readRetentionLimit
        return sorted.filter { record in
            guard record.isRead else { return true }
            guard remainingReadSlots > 0 else { return false }
            remainingReadSlots -= 1
            return true
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
