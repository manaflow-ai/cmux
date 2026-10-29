import Foundation
import os
import SQLite3
import CmuxNextCompat

/// `ChiefAdoption`'s copy of a live SQLite database: SQLite's online backup API reads a
/// consistent snapshot while the conversation owner writes it, into one self-contained file
/// (rollback journal, no `-wal`), so the backup opens on its own, even read-only.
nonisolated extension ChiefAdoption {
    /// Runs `run(by:)` off the main actor; the outcome, or nil when the backup failed (logged;
    /// the next launch tries again).
    @concurrent static func runOffMain(home: ChiefHome, by build: String, logger: Logger) async -> Outcome? {
        do {
            let outcome = try ChiefAdoption(home: home).run(by: build)
            logger.info("chief adoption: \(String(describing: outcome), privacy: .public)")
            return outcome
        } catch {
            logger.error("chief adoption failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A regular file that starts with the SQLite header (never opens a FIFO or a socket).
    static func isSQLite(_ url: URL) -> Bool {
        var info = stat()
        guard blockingLstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let handle = try? FileHandle.blockingForReading(from: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.blockingRead(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// A journal file of one of `databases` (copied inside the database's backup).
    static func isSidecar(_ name: String, of databases: Set<String>) -> Bool {
        ["-wal", "-shm", "-journal"].contains { name.hasSuffix($0) && databases.contains(String(name.dropLast($0.count))) }
    }

    /// An APFS clone of one regular file (a byte copy where cloning fails).
    static func cloneFile(from source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    /// Why a database copy failed; `busy`: another connection held it too long (retried next launch).
    struct BackupError: Error, CustomStringConvertible {
        var description: String
        var busy: Bool
    }

    /// Copies the database at `source` to the new file `target` with the online backup API.
    static func backUpDatabase(from source: URL, to target: URL) throws {
        var from: OpaquePointer?
        var to: OpaquePointer?
        defer {
            sqlite3_close_v2(from)
            sqlite3_close_v2(to)
        }
        // Read-write (never created): a WAL database of a live writer needs its -shm shared.
        guard blockingSQLiteOpen(source.path, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              blockingSQLiteOpen(target.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let from, let to else { throw failure("open", from ?? to, source) }
        sqlite3_busy_timeout(from, 10_000)
        // When this is the last connection, its close checkpoints: as durably as the owner does.
        _ = blockingSQLiteExec(from, "PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON")
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else { throw failure("backup_init", to, source) }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw failure("backup_step \(step)", to, source, busy: step == SQLITE_BUSY || step == SQLITE_LOCKED)
        }
        // One file: the copy keeps no WAL of its own (the pragma answers the mode it set).
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard blockingSQLitePrepare(to, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK,
              blockingSQLiteStep(statement) == SQLITE_ROW, let mode = sqlite3_column_text(statement, 0),
              String(cString: mode) == "delete" else { throw failure("journal_mode", to, source) }
    }

    private static func failure(_ what: String, _ db: OpaquePointer?, _ source: URL, busy: Bool = false) -> BackupError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        return BackupError(description: "\(what) \(source.lastPathComponent): \(message)", busy: busy)
    }
}
