@testable import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

/// How `HermesAgentIndex` opens Hermes's `state.db`: in place while Hermes is
/// running, and through a private snapshot only when SQLite can't read it in place.
@Suite("HermesAgentIndex state database")
struct HermesAgentIndexStateDatabaseTests {
    @Test("Reads Hermes's live WAL database in place while Hermes is writing")
    func readsLiveWALDatabaseInPlace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Characters that need escaping in a SQLite `file:` URI.
        let hermesHome = root.appendingPathComponent("Hermes Home ?#%", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let dbURL = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        let snapshotRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        try exec(dbURL, "PRAGMA journal_mode = WAL;")
        try makeHermesStateDB(at: dbURL)
        let writer = try openConnection(dbURL)
        defer { sqlite3_close(writer) }
        try exec(writer, """
        PRAGMA wal_autocheckpoint = 0;
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('committed', 'tui', 'model-a', 10, 'Committed');
        BEGIN IMMEDIATE;
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('uncommitted', 'tui', 'model-a', 20, 'Uncommitted');
        """)

        let inspection = HermesAgentIndex.recoveryInspection(
            sessionIDs: ["committed", "uncommitted", "missing"],
            cwd: nil,
            startedAt: nil,
            before: nil,
            stateDBPath: dbURL.path,
            temporaryDirectory: snapshotRoot
        )
        #expect(inspection?.existingSessionIDs == ["committed"])

        let search = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path,
            temporaryDirectory: snapshotRoot
        )
        #expect(search.errors.isEmpty)
        #expect(search.sessions.map(\.sessionId) == ["committed"])

        let read = try HermesAgentIndex.withStateDatabase(
            stateDBPath: dbURL.path,
            snapshotPrefix: "cmux-hermes-agent-test",
            temporaryDirectory: snapshotRoot
        ) { db -> (path: String?, readOnly: Bool, snapshotEntries: [String]) in
            (
                sqlite3_db_filename(db, "main").map { String(cString: $0) },
                sqlite3_db_readonly(db, "main") == 1,
                try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path)
            )
        }
        #expect(read?.path.map(resolvedPath) == resolvedPath(dbURL.path))
        #expect(read?.readOnly == true)
        #expect(read?.snapshotEntries == [])

        try exec(writer, "COMMIT;")
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).isEmpty)
    }

    @Test("Reports a locked database as unavailable instead of copying it")
    func lockedDatabaseIsUnavailable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        let snapshotRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        try exec(dbURL, "PRAGMA journal_mode = DELETE;")
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('locked-session', 'cli', 'model-a', 10, 'Locked session');
        """)
        let writer = try openConnection(dbURL)
        defer { sqlite3_close(writer) }
        try exec(writer, "BEGIN EXCLUSIVE;")

        let inspection = HermesAgentIndex.recoveryInspection(
            sessionIDs: ["locked-session"],
            cwd: nil,
            startedAt: nil,
            before: nil,
            stateDBPath: dbURL.path,
            temporaryDirectory: snapshotRoot
        )
        #expect(inspection == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).isEmpty)

        try exec(writer, "COMMIT;")
    }

    @Test("Snapshots a rollback-journal database instead of holding its lock")
    func snapshotsRollbackJournalDatabase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        let snapshotRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        try exec(dbURL, "PRAGMA journal_mode = DELETE;")
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('rollback-session', 'cli', 'model-a', 10, 'Rollback session');
        """)

        let read = try HermesAgentIndex.withStateDatabase(
            stateDBPath: dbURL.path,
            snapshotPrefix: "cmux-hermes-agent-test",
            temporaryDirectory: snapshotRoot
        ) { db -> (sessionIDs: [String], path: String?) in
            (
                try sessionIDs(db),
                sqlite3_db_filename(db, "main").map { String(cString: $0) }
            )
        }

        #expect(read?.sessionIDs == ["rollback-session"])
        #expect(read?.path.map(resolvedPath) != resolvedPath(dbURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).isEmpty)
    }

    @Test("Snapshots a WAL database whose sidecars Hermes removed")
    func snapshotsSidecarlessWALDatabase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        let snapshotRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        try exec(dbURL, "PRAGMA journal_mode = WAL;")
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('wal-session', 'tui', 'model-a', 10, 'WAL session');
        PRAGMA wal_checkpoint(TRUNCATE);
        """)
        for sidecar in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + sidecar)
        }

        let read = try HermesAgentIndex.withStateDatabase(
            stateDBPath: dbURL.path,
            snapshotPrefix: "cmux-hermes-agent-test",
            temporaryDirectory: snapshotRoot
        ) { db -> (sessionIDs: [String], path: String?, snapshotEntries: Int) in
            (
                try sessionIDs(db),
                sqlite3_db_filename(db, "main").map { String(cString: $0) },
                try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).count
            )
        }

        #expect(read?.sessionIDs == ["wal-session"])
        #expect(read?.path.map(resolvedPath) != resolvedPath(dbURL.path))
        #expect(read?.snapshotEntries == 1)
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHermesStateDB(at url: URL) throws {
        try exec(url, """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          user_id TEXT,
          model TEXT,
          model_config TEXT,
          system_prompt TEXT,
          parent_session_id TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          end_reason TEXT,
          message_count INTEGER DEFAULT 0,
          tool_call_count INTEGER DEFAULT 0,
          input_tokens INTEGER DEFAULT 0,
          output_tokens INTEGER DEFAULT 0,
          cache_read_tokens INTEGER DEFAULT 0,
          cache_write_tokens INTEGER DEFAULT 0,
          reasoning_tokens INTEGER DEFAULT 0,
          billing_provider TEXT,
          billing_base_url TEXT,
          billing_mode TEXT,
          estimated_cost_usd REAL,
          actual_cost_usd REAL,
          cost_status TEXT,
          cost_source TEXT,
          pricing_version TEXT,
          cwd TEXT,
          title TEXT,
          api_call_count INTEGER DEFAULT 0
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_call_id TEXT,
          tool_calls TEXT,
          tool_name TEXT,
          timestamp REAL NOT NULL,
          token_count INTEGER,
          finish_reason TEXT,
          reasoning TEXT,
          reasoning_content TEXT,
          reasoning_details TEXT,
          codex_reasoning_items TEXT,
          codex_message_items TEXT
        );
        """)
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        let db = try openConnection(dbURL)
        defer { sqlite3_close(db) }
        try exec(db, sql)
    }

    private func openConnection(_ dbURL: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw HermesAgentIndexError.sqlite("open failed")
        }
        return db
    }

    private func sessionIDs(_ db: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM sessions ORDER BY id", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw HermesAgentIndexError.sqlite("prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return ids
    }

    private func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }
}
