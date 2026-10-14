import Foundation
import os
import SQLite3

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
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// A journal file of one of `databases` (copied inside the database's backup).
    static func isSidecar(_ name: String, of databases: Set<String>) -> Bool {
        ["-wal", "-shm", "-journal"].contains { name.hasSuffix($0) && databases.contains(String(name.dropLast($0.count))) }
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
        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_open_v2(target.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let from, let to else { throw failure("open", from ?? to, source) }
        sqlite3_busy_timeout(from, 10_000)
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else { throw failure("backup_init", to, source) }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw failure("backup_step \(step)", to, source) }
        // One file: the copy keeps no WAL of its own.
        guard sqlite3_exec(to, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw failure("journal_mode", to, source) }
    }

    private static func failure(_ what: String, _ db: OpaquePointer?, _ source: URL) -> NSError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        return NSError(domain: "ChiefAdoption", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what) \(source.lastPathComponent): \(message)"])
    }
}
