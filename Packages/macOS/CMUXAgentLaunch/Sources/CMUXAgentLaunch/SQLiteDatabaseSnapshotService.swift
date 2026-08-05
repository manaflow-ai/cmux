import Darwin
import Foundation
import SQLite3

/// Copies a live SQLite database through SQLite's online backup API.
///
/// The resulting file represents one consistent source transaction and does not
/// depend on separately copied WAL or shared-memory sidecars.
///
/// ```swift
/// try SQLiteDatabaseSnapshotService().copyDatabase(
///     from: liveDatabasePath,
///     to: snapshotPath,
///     maximumBytes: 128 * 1_024 * 1_024
/// )
/// ```
public struct SQLiteDatabaseSnapshotService {
    private let fileManager: FileManager
    private let pagesPerStep: Int32
    private let maximumDuration: Duration
    private let now: () -> ContinuousClock.Instant
    private let stepObserver: (() throws -> Void)?

    /// Creates a database snapshot service.
    /// - Parameters:
    ///   - fileManager: Filesystem dependency used to remove temporary sidecars.
    ///   - maximumDuration: Total backup duration before failing. The ten-second
    ///     default prevents a live writer from starving an incremental backup.
    ///   - now: Monotonic clock read used to enforce `maximumDuration`.
    public init(
        fileManager: FileManager = .default,
        maximumDuration: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.fileManager = fileManager
        pagesPerStep = 64
        self.maximumDuration = maximumDuration
        self.now = now
        stepObserver = nil
    }

    init(
        fileManager: FileManager = .default,
        pagesPerStep: Int32,
        maximumDuration: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
        stepObserver: @escaping () throws -> Void
    ) {
        self.fileManager = fileManager
        self.pagesPerStep = max(1, pagesPerStep)
        self.maximumDuration = maximumDuration
        self.now = now
        self.stepObserver = stepObserver
    }

    /// Copies one consistent transaction from a live SQLite database.
    /// - Parameters:
    ///   - sourcePath: Path to the live source database.
    ///   - destinationPath: Path where the standalone snapshot is created.
    ///   - maximumBytes: Optional upper bound for the logical database image.
    /// - Throws: ``SQLiteDatabaseSnapshotError`` or ``CancellationError`` when
    ///   the snapshot cannot complete.
    public func copyDatabase(
        from sourcePath: String,
        to destinationPath: String,
        maximumBytes: Int? = nil
    ) throws {
        if let maximumBytes, maximumBytes < 0 {
            throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        }
        try Task.checkCancellation()
        let startedAt = now()
        try checkDeadline(startedAt: startedAt)
        let sourceDescriptor = try validatedRegularSourceDescriptor(path: sourcePath)
        defer { _ = Darwin.close(sourceDescriptor) }

        var sourceDatabase: OpaquePointer?
        let sourceOpenResult = sqlite3_open_v2(
            sourcePath,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceOpenResult == SQLITE_OK, let sourceDatabase else {
            let message = sqliteMessage(sourceDatabase, fallback: "cannot open source database")
            if let sourceDatabase {
                _ = sqlite3_close(sourceDatabase)
            }
            throw SQLiteDatabaseSnapshotError.sqlite(message)
        }
        defer { _ = sqlite3_close(sourceDatabase) }

        let pageSize = try databasePageSize(sourceDatabase)
        try checkDeadline(startedAt: startedAt)
        var destinationDatabase: OpaquePointer?
        let destinationOpenResult = sqlite3_open_v2(
            destinationPath,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationOpenResult == SQLITE_OK, let destinationDatabase else {
            let message = sqliteMessage(
                destinationDatabase,
                fallback: "cannot open snapshot database"
            )
            if let destinationDatabase {
                _ = sqlite3_close(destinationDatabase)
            }
            throw SQLiteDatabaseSnapshotError.sqlite(message)
        }
        var destinationDatabaseNeedsClose: OpaquePointer? = destinationDatabase
        defer {
            if let destinationDatabaseNeedsClose {
                _ = sqlite3_close(destinationDatabaseNeedsClose)
            }
        }

        guard let initializedBackup = sqlite3_backup_init(
            destinationDatabase,
            "main",
            sourceDatabase,
            "main"
        ) else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(destinationDatabase, fallback: "cannot initialize backup")
            )
        }
        var backup: OpaquePointer? = initializedBackup
        defer {
            if let unfinishedBackup = backup {
                _ = sqlite3_backup_finish(unfinishedBackup)
            }
        }

        var busyRetryCount = 0
        while true {
            try Task.checkCancellation()
            try checkDeadline(startedAt: startedAt)
            guard let activeBackup = backup else {
                throw SQLiteDatabaseSnapshotError.sqlite("backup state became unavailable")
            }
            let stepResult = sqlite3_backup_step(activeBackup, pagesPerStep)
            try enforceMaximumBytes(
                backup: activeBackup,
                pageSize: pageSize,
                maximumBytes: maximumBytes
            )
            if stepResult != SQLITE_DONE {
                try checkDeadline(startedAt: startedAt)
            }

            switch stepResult {
            case SQLITE_DONE:
                let finishResult = sqlite3_backup_finish(activeBackup)
                backup = nil
                guard finishResult == SQLITE_OK else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        sqliteMessage(destinationDatabase, fallback: "cannot finish backup")
                    )
                }
                try makeSnapshotStandalone(destinationDatabase)
                try Task.checkCancellation()
                let closeResult = sqlite3_close(destinationDatabase)
                guard closeResult == SQLITE_OK else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        sqliteMessage(destinationDatabase, fallback: "cannot close snapshot database")
                    )
                }
                destinationDatabaseNeedsClose = nil
                try removeSnapshotSidecars(destinationPath: destinationPath)
                return
            case SQLITE_OK:
                busyRetryCount = 0
                try stepObserver?()
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyRetryCount += 1
                guard busyRetryCount <= 100 else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        sqliteMessage(destinationDatabase, fallback: "source database remained busy")
                    )
                }
                try Task.checkCancellation()
                _ = sqlite3_sleep(10)
            default:
                throw SQLiteDatabaseSnapshotError.sqlite(
                    sqliteMessage(destinationDatabase, fallback: "backup step failed")
                )
            }
        }
    }

    private func checkDeadline(startedAt: ContinuousClock.Instant) throws {
        guard startedAt.duration(to: now()) < maximumDuration else {
            throw SQLiteDatabaseSnapshotError.timedOut(
                maximumDuration: maximumDuration
            )
        }
    }

    /// Opens special files without waiting for a peer, then keeps the validated
    /// regular file alive while SQLite opens the same source path. This prevents
    /// FIFOs and devices from bypassing the snapshot deadline inside sqlite3_open_v2.
    private func validatedRegularSourceDescriptor(path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open source database")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database is not a regular file"
            )
        }
        return descriptor
    }

    private func removeSnapshotSidecars(destinationPath: String) throws {
        for suffix in ["-wal", "-shm"] {
            let sidecarPath = destinationPath + suffix
            guard fileManager.fileExists(atPath: sidecarPath) else { continue }
            do {
                try fileManager.removeItem(atPath: sidecarPath)
            } catch {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot remove snapshot sidecar: \(error.localizedDescription)"
                )
            }
        }
    }

    private func makeSnapshotStandalone(_ database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(
            database,
            "PRAGMA journal_mode = DELETE",
            nil,
            nil,
            &errorMessage
        )
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? sqliteMessage(database, fallback: "cannot finalize standalone snapshot")
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseSnapshotError.sqlite(message)
        }
    }

    private func databasePageSize(_ database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA page_size", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(database, fallback: "cannot read database page size")
            )
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(database, fallback: "cannot read database page size")
            )
        }
        let pageSize = sqlite3_column_int64(statement, 0)
        guard pageSize > 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("database reported an invalid page size")
        }
        return pageSize
    }

    private func enforceMaximumBytes(
        backup: OpaquePointer,
        pageSize: Int64,
        maximumBytes: Int?
    ) throws {
        guard let maximumBytes else { return }
        let pageCount = Int64(sqlite3_backup_pagecount(backup))
        guard pageCount >= 0,
              pageCount <= Int64(maximumBytes) / pageSize else {
            throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        }
    }

    private func sqliteMessage(
        _ database: OpaquePointer?,
        fallback: String
    ) -> String {
        guard let database,
              let message = sqlite3_errmsg(database) else {
            return fallback
        }
        return String(cString: message)
    }
}
