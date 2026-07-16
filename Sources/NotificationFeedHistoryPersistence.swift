import Foundation
import os

nonisolated private let notificationFeedPersistenceLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-feed-persistence"
)

/// Serializes atomic notification-feed writes and rejects stale revisions.
actor NotificationFeedHistoryPersistence {
    private let fileURL: URL?
    private let fileManager: FileManager
    private var lastPersistedRevision: Int

    init(fileURL: URL?, fileManager: FileManager, initialRevision: Int) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        lastPersistedRevision = initialRevision
    }

    nonisolated static func loadSnapshot(
        fileURL: URL?,
        fileManager: FileManager
    ) -> NotificationFeedHistorySnapshot? {
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(NotificationFeedHistorySnapshot.self, from: data)
            guard snapshot.version == NotificationFeedHistorySnapshot.currentVersion else { return nil }
            return snapshot
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed load failed file=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func persist(_ snapshot: NotificationFeedHistorySnapshot) {
        guard snapshot.revision > lastPersistedRevision else { return }
        guard let fileURL else {
            lastPersistedRevision = snapshot.revision
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
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed persist failed file=\(fileURL.path, privacy: .public) revision=\(snapshot.revision) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
