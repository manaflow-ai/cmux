import Foundation
import SQLite3

/// A disposable copy of Hermes's database and its live WAL sidecars.
struct HermesAgentDatabaseSnapshot {
    let databaseURL: URL
    private let directoryURL: URL

    init(databaseURL: URL, directoryURL: URL) {
        self.databaseURL = databaseURL
        self.directoryURL = directoryURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

extension HermesAgentIndex {
    /// Runs a synchronous read against Hermes's `state.db`.
    ///
    /// A WAL database is read in place through a read-only connection, which
    /// never blocks Hermes's writer. Anything else is read from a private
    /// snapshot (see `openLiveDatabase`).
    ///
    /// - Returns: The body's result, or `nil` when the database doesn't exist.
    static func withStateDatabase<T>(
        stateDBPath: String,
        snapshotPrefix: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T? {
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return nil }
        if let database = try openLiveDatabase(stateDBPath) {
            // `close_v2` releases the read transaction even if a statement was
            // left unfinalized; a lingering reader would block Hermes's checkpoints.
            defer { sqlite3_close_v2(database) }
            return try body(database)
        }
        guard let snapshot = try makeSnapshot(
            stateDBPath: stateDBPath,
            prefix: snapshotPrefix,
            in: temporaryDirectory
        ) else {
            return nil
        }
        defer { snapshot.remove() }
        return try withDatabase(snapshot.databaseURL.path, body)
    }

    /// Opens Hermes's live database read-only.
    ///
    /// - Returns: The open connection, or `nil` when the database should be read
    ///   through a snapshot:
    ///   - Hermes leaves `state.db` in WAL mode and removes its `-wal`/`-shm`
    ///     sidecars when its last connection closes. A read-only connection can't
    ///     create `-wal`, so SQLite reports `SQLITE_CANTOPEN` on the first read.
    ///     `SQLITE_READONLY` covers a shared-memory index this process can't write.
    ///   - Outside WAL mode, a reader's shared lock blocks Hermes's commits for the
    ///     whole query, and searches scan every message.
    ///
    ///   Other errors, including `SQLITE_BUSY`, throw: a busy database is being
    ///   written, which is the worst time to copy it.
    private static func openLiveDatabase(_ path: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        var result = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if result == SQLITE_OK, let db {
            // Short: callers treat a failed read as "unavailable" and retry later,
            // and some of them run while restoring the UI.
            _ = sqlite3_busy_timeout(db, 250)
            // Opening is lazy; the first read attaches the WAL and its index.
            result = sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil)
            if result == SQLITE_OK {
                if journalMode(db) == "wal" { return db }
                sqlite3_close_v2(db)
                return nil
            }
        }
        let message = sqliteMessage(db) ?? "open failed with code \(result)"
        sqlite3_close_v2(db)
        switch result & 0xFF {
        case SQLITE_CANTOPEN, SQLITE_READONLY:
            return nil
        default:
            throw HermesAgentIndexError.sqlite(message)
        }
    }

    private static func journalMode(_ database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqliteText(statement, 0)?.lowercased()
    }

    /// Copies a Hermes database and any WAL sidecars into a private directory.
    static func makeSnapshot(
        stateDBPath: String,
        prefix: String,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> HermesAgentDatabaseSnapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateDBPath) else { return nil }

        let snapshotDir = temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("state.db", isDirectory: false)
        do {
            try fileManager.copyItem(atPath: stateDBPath, toPath: snapshotDB.path)
            for sidecar in ["-wal", "-shm"] {
                let source = stateDBPath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }
        return HermesAgentDatabaseSnapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }

    /// Opens a private snapshot for the duration of a synchronous read.
    static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        // `path` is always a private temporary snapshot. Hermes can leave the
        // main database in persistent WAL mode after removing its sidecars;
        // SQLite must be allowed to recreate transient `-wal`/`-shm` files in
        // the snapshot directory before it can read that fully checkpointed DB.
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = sqliteMessage(db) ?? "open failed with code \(openResult)"
            sqlite3_close(db)
            throw HermesAgentIndexError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_busy_timeout(db, 50)
        return try body(db)
    }
}
