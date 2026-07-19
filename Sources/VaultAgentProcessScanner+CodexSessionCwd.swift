import Foundation
import SQLite3

final class CodexSessionCwdLookupCache {
    private final class DatabaseLookup {
        let database: OpaquePointer
        let statement: OpaquePointer

        init(database: OpaquePointer, statement: OpaquePointer) {
            self.database = database
            self.statement = statement
        }

        deinit {
            sqlite3_finalize(statement)
            sqlite3_close(database)
        }
    }

    private enum CachedDatabase {
        case unavailable
        case available(DatabaseLookup)
    }

    private let fileManager: FileManager
    private var cwdByDatabaseAndSession: [String: String?] = [:]
    private var databaseByPath: [String: CachedDatabase] = [:]

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
        let cacheKey = dbPath + "\u{0}" + sessionId
        // dict[key] is String?? here: .some(nil) is a memoized negative result.
        if let cached = cwdByDatabaseAndSession[cacheKey] {
            return cached
        }

        guard let lookup = databaseLookup(at: dbPath) else {
            cwdByDatabaseAndSession.updateValue(nil, forKey: cacheKey)
            return nil
        }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_reset(lookup.statement)
        sqlite3_clear_bindings(lookup.statement)
        sqlite3_bind_text(lookup.statement, 1, sessionId, -1, SQLITE_TRANSIENT_FN)
        defer {
            sqlite3_reset(lookup.statement)
            sqlite3_clear_bindings(lookup.statement)
        }
        guard sqlite3_step(lookup.statement) == SQLITE_ROW,
              let cwd = normalizedCodexCwdValue(SessionIndexStore.sqliteText(lookup.statement, 0)) else {
            // updateValue stores .some(nil); subscript nil-assignment would remove the key.
            cwdByDatabaseAndSession.updateValue(nil, forKey: cacheKey)
            return nil
        }
        cwdByDatabaseAndSession[cacheKey] = cwd
        return cwd
    }

    private func databaseLookup(at dbPath: String) -> DatabaseLookup? {
        if let cached = databaseByPath[dbPath] {
            switch cached {
            case .unavailable:
                return nil
            case .available(let lookup):
                return lookup
            }
        }

        guard fileManager.fileExists(atPath: dbPath) else {
            databaseByPath[dbPath] = .unavailable
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            databaseByPath[dbPath] = .unavailable
            return nil
        }

        let sql = "SELECT cwd FROM threads WHERE id = ? AND archived = 0 LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            sqlite3_close(database)
            databaseByPath[dbPath] = .unavailable
            return nil
        }

        let lookup = DatabaseLookup(database: database, statement: statement)
        databaseByPath[dbPath] = .available(lookup)
        return lookup
    }

    private func normalizedCodexCwdValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
