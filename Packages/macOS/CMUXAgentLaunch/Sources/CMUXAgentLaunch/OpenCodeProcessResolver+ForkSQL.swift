public import Foundation
import CmuxFoundation
import SQLite3

extension OpenCodeProcessResolver {
    /// Looks up the most recently updated OpenCode session forked from
    /// `parentSessionId` within `workingDirectory`, reading a read-only snapshot
    /// of the OpenCode database.
    ///
    /// The query matches the session whose `directory` equals the standardized
    /// working directory and whose `parent_id` equals the parent session id,
    /// ordered by `time_updated` descending. Returns `nil` when either input is
    /// empty, the snapshot cannot be taken or opened, or no matching row exists.
    ///
    /// - Parameters:
    ///   - workingDirectory: The fork's working directory; standardized before matching.
    ///   - parentSessionId: The fork-parent session id to match on `parent_id`.
    ///   - fileManager: Reserved for future filesystem injection; the snapshot
    ///     itself uses `FileManager.default`.
    public func latestOpenCodeSessionId(
        workingDirectory: String?,
        parentSessionId: String?,
        fileManager: FileManager
    ) -> String? {
        _ = fileManager
        let snapshot: OpenCodeDatabaseSnapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(prefix: "cmux-opencode-process") else {
                return nil
            }
            snapshot = madeSnapshot
        } catch {
            return nil
        }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        guard let parentId = Self.normalized(parentSessionId) else {
            return nil
        }
        guard let cwd = Self.normalized(workingDirectory).map({ ($0 as NSString).standardizingPath }) else {
            return nil
        }
        let sql = """
            SELECT id FROM session
            WHERE directory = ?
              AND parent_id = ?
            ORDER BY time_updated DESC
            LIMIT 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        sqlite3_bind_text(stmt, bindIndex, cwd, -1, SQLITE_TRANSIENT_FN)
        bindIndex += 1
        sqlite3_bind_text(stmt, bindIndex, parentId, -1, SQLITE_TRANSIENT_FN)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let sessionId = stmt.sqliteColumnText(0),
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }
}
