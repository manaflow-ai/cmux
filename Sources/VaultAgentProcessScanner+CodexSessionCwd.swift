import Foundation
import SQLite3

final class CodexSessionCwdLookupCache {
    private let fileManager: FileManager
    private var cwdByDatabaseAndSession: [String: String?] = [:]

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func workingDirectory(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> String? {
        guard kind == .codex else { return nil }
        guard let sessionId = normalizedCodexCwdValue(sessionId) else { return nil }
        let codexHome = ((normalizedCodexCwdValue(launchCommand?.environment?["CODEX_HOME"]) ?? "~/.codex") as NSString)
            .expandingTildeInPath
        let dbPath = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path
        guard fileManager.fileExists(atPath: dbPath) else { return nil }
        let cacheKey = dbPath + "\u{0}" + sessionId
        // dict[key] is String?? here: .some(nil) is a memoized negative result.
        if let cached = cwdByDatabaseAndSession[cacheKey] {
            return cached
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT cwd FROM threads WHERE id = ? AND archived = 0 LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_FN)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cwd = normalizedCodexCwdValue(SessionIndexStore.sqliteText(stmt, 0)) else {
            // updateValue stores .some(nil); subscript nil-assignment would remove the key.
            cwdByDatabaseAndSession.updateValue(nil, forKey: cacheKey)
            return nil
        }
        cwdByDatabaseAndSession[cacheKey] = cwd
        return cwd
    }

    private func normalizedCodexCwdValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
