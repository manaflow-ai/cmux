import Foundation

/// Creates bounded, cancellation-aware snapshots of the Hermes SQLite store.
struct HermesAgentDatabaseSnapshotService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func make(
        stateDBPath: String,
        prefix: String,
        maximumTotalBytes: Int? = nil
    ) throws -> HermesAgentDatabaseSnapshot? {
        guard fileManager.fileExists(atPath: stateDBPath) else { return nil }
        if let maximumTotalBytes, maximumTotalBytes < 0 {
            throw HermesAgentIndexError.snapshotTooLarge(maximumBytes: maximumTotalBytes)
        }
        try Task.checkCancellation()

        let snapshotDirectory = try SQLiteDatabaseSnapshotService
            .createPrivateTemporaryDirectory(
                prefix: prefix,
                fileManager: fileManager
            )

        let snapshotDatabase = snapshotDirectory.appendingPathComponent(
            "state.db",
            isDirectory: false
        )
        do {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: stateDBPath,
                to: snapshotDatabase.path,
                maximumBytes: maximumTotalBytes
            )
        } catch SQLiteDatabaseSnapshotError.snapshotTooLarge(let maximumBytes) {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw HermesAgentIndexError.snapshotTooLarge(maximumBytes: maximumBytes)
        } catch SQLiteDatabaseSnapshotError.timedOut {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw HermesAgentIndexError.sqlite("snapshot timed out")
        } catch SQLiteDatabaseSnapshotError.sqlite(let message) {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw HermesAgentIndexError.sqlite(message)
        } catch {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw error
        }

        return HermesAgentDatabaseSnapshot(
            databaseURL: snapshotDatabase,
            directoryURL: snapshotDirectory,
            fileManager: fileManager
        )
    }
}
