import Foundation
import SQLite3

/// Reads Codex's own natively-generated thread title straight from
/// `~/.codex/state_5.sqlite`'s `threads.title` column — the same database the
/// Vault session index already reads, narrowed to one session id.
///
/// This exists so both the `cmux` CLI (the detached Codex Stop-hook process,
/// entirely outside the app) and the app itself can resolve a Codex session's
/// authoritative title without duplicating the SQLite read, and without the
/// app ever performing the file-copy-and-query work synchronously on the
/// socket-handling path (cmux #11144).
public enum CodexNativeTitleStore {
    /// Codex's native title for `sessionId`, or nil when the database is
    /// missing, the session has no row, or its title is empty — every case a
    /// silent no-op for the caller. Nothing here infers a title from cwd or
    /// rollout content: Codex already computed this title itself.
    public static func title(
        forSessionId sessionId: String,
        dbPath: String = ("~/.codex/state_5.sqlite" as NSString).expandingTildeInPath
    ) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return nil }

        // A snapshot copy avoids holding a live handle on the file Codex's
        // own process may concurrently write, mirroring the Vault index's
        // existing read pattern for the same database.
        let snapshotDir = fm.temporaryDirectory.appendingPathComponent(
            "cmux-codex-native-title-\(UUID().uuidString)", isDirectory: true
        )
        do { try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true) } catch { return nil }
        defer { try? fm.removeItem(at: snapshotDir) }
        let snapshotDB = snapshotDir.appendingPathComponent("state.db")
        do { try fm.copyItem(atPath: dbPath, toPath: snapshotDB.path) } catch { return nil }
        for sidecar in ["-wal", "-shm"] {
            let src = dbPath + sidecar
            let dst = snapshotDB.path + sidecar
            if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: dst) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshotDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT title FROM threads WHERE id = ?1 AND archived = 0 LIMIT 1", -1, &stmt, nil
        ) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let title = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
