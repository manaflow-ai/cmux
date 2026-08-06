import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

@Suite("HermesAgentIndex")
struct HermesAgentIndexTests {
    @Test("Loads CLI and TUI sessions from state database")
    func loadsCliAndTUISessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES
          ('old', 'cli', 'model-a', 10, 'Old session'),
          ('new', 'tui', 'model-b', 20, NULL),
          ('tool-only', 'tool', 'model-c', 30, 'Hidden tool session');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('old', 'user', 'older prompt', 11),
          ('new', 'user', 'new prompt first line', 21),
          ('new', 'assistant', 'new answer', 22),
          ('tool-only', 'user', 'hidden', 31);
        """)

        let result = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["new", "old"])
        #expect(result.sessions.first?.source == "tui")
        #expect(result.sessions.first?.title == "new answer")
        #expect(result.sessions.first?.modified == Date(timeIntervalSince1970: 22))
    }

    @Test("Searches messages and skips directory scoped requests")
    func searchesMessagesAndSkipsDirectoryScopedRequests() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES ('session-a', 'assistant', 'Needle text', 11);
        """)

        let found = HermesAgentIndex.loadSessions(
            needle: "needle",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )
        let scoped = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: "/tmp/repo",
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(found.sessions.map(\.sessionId) == ["session-a"])
        #expect(scoped.sessions.isEmpty)
    }

    @Test("Loads transcript and decodes Hermes JSON content")
    func loadsTranscriptAndDecodesHermesJSONContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, tool_name, tool_calls, timestamp)
        VALUES
          ('session-a', 'user', char(0) || 'json:[{"type":"text","text":"structured hello"}]', NULL, NULL, 11),
          ('session-a', 'tool', 'ran command', 'terminal', '{"command":"pwd"}', 12);
        """)

        let turns = try HermesAgentIndex.loadTranscript(
            sessionId: "session-a",
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(turns.count == 2)
        #expect(turns[0].role == "user")
        #expect(turns[0].content == "structured hello")
        #expect(turns[1].toolName == "terminal")
        #expect(turns[1].content.contains("ran command"))
        #expect(turns[1].content.contains("pwd"))
    }

    @Test("Loads the latest transcript suffix in chronological order")
    func loadsLatestTranscriptSuffixInChronologicalOrder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('session-a', 'user', 'turn one', 11),
          ('session-a', 'assistant', 'turn two', 12),
          ('session-a', 'user', 'turn three', 13),
          ('session-a', 'assistant', 'turn four', 14);
        """)

        let turns = try HermesAgentIndex.loadTranscript(
            sessionId: "session-a",
            limit: 2,
            latest: true,
            stateDBPath: dbURL.path
        )

        #expect(turns.map(\.content) == ["turn three", "turn four"])
    }

    @Test("Preserves the opening user request before the latest suffix")
    func preservesOpeningUserBeforeLatestSuffix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('session-a', 'user', 'opening request', 11),
          ('session-a', 'assistant', 'old answer', 12),
          ('session-a', 'user', 'latest follow-up', 13),
          ('session-a', 'assistant', 'latest answer', 14);
        """)

        let turns = try HermesAgentIndex.loadTranscript(
            sessionId: "session-a",
            limit: 3,
            latest: true,
            preservingOpeningUser: true,
            stateDBPath: dbURL.path
        )

        #expect(turns.map(\.content) == ["opening request", "latest follow-up", "latest answer"])
    }

    @Test("Applies the dialogue limit after excluding trailing tool rows")
    func appliesDialogueLimitAfterExcludingTrailingToolRows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        let toolRows = (0..<1_001)
            .map { index in
                "('session-a', 'tool', 'tool output \(index)', 'terminal', \(index + 13))"
            }
            .joined(separator: ",\n")
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('session-a', 'user', 'opening request', 11),
          ('session-a', 'assistant', 'LATEST-HERMES-DIALOGUE', 12);
        INSERT INTO messages (session_id, role, content, tool_name, timestamp)
        VALUES
        \(toolRows);
        """)

        let turns = try HermesAgentIndex.loadTranscript(
            sessionId: "session-a",
            limit: 2,
            latest: true,
            preservingOpeningUser: true,
            dialogueOnly: true,
            stateDBPath: dbURL.path
        )

        #expect(turns.map(\.content) == [
            "opening request",
            "LATEST-HERMES-DIALOGUE",
        ])
    }

    @Test("Rejects transcript snapshots above the aggregate byte limit")
    func rejectsTranscriptSnapshotAboveAggregateByteLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        #expect(
            throws: HermesAgentIndexError.snapshotTooLarge(maximumBytes: 8)
        ) {
            _ = try HermesAgentIndex.loadTranscript(
                sessionId: "session-a",
                limit: 10,
                stateDBPath: dbURL.path,
                maximumSnapshotBytes: 8
            )
        }
    }

    @Test("Creates transcript snapshots with owner-only permissions")
    func createsTranscriptSnapshotsWithOwnerOnlyPermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        let snapshot = try #require(try HermesAgentDatabaseSnapshotService().make(
            stateDBPath: dbURL.path,
            prefix: "cmux-hermes-private-test"
        ))
        defer { snapshot.remove() }
        let directoryPermissions = try permissions(
            at: snapshot.databaseURL.deletingLastPathComponent()
        )
        let databasePermissions = try permissions(at: snapshot.databaseURL)

        #expect(directoryPermissions == 0o700)
        #expect(databasePermissions == 0o600)
    }

    @Test("Online backup stays consistent when the WAL changes between steps")
    func onlineBackupStaysConsistentAcrossConcurrentCommit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("live.db", isDirectory: false)
        let snapshotURL = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeLargeWALDatabase(at: sourceURL)

        var committedNewGeneration = false
        let service = SQLiteDatabaseSnapshotService(
            pagesPerStep: 1,
            stepObserver: {
                guard !committedNewGeneration else { return }
                committedNewGeneration = true
                try exec(sourceURL, """
                BEGIN IMMEDIATE;
                UPDATE records SET generation = 2;
                COMMIT;
                """)
            }
        )

        try service.copyDatabase(
            from: sourceURL.path,
            to: snapshotURL.path
        )

        #expect(committedNewGeneration)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path + "-shm"))
        #expect(
            try scalarInt(
                snapshotURL,
                "SELECT COUNT(*) FROM records WHERE generation <> 2"
            ) == 0
        )
    }

    @Test("Online backup reads uncheckpointed rows from a live WAL")
    func onlineBackupReadsLiveWAL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("live.db", isDirectory: false)
        let snapshotURL = root.appendingPathComponent("snapshot.db", isDirectory: false)
        let writer = Process()
        let writerInput = Pipe()
        let writerError = Pipe()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        writer.arguments = [sourceURL.path]
        writer.standardInput = writerInput
        writer.standardOutput = Pipe()
        writer.standardError = writerError
        try writer.run()
        defer {
            try? writerInput.fileHandleForWriting.close()
            if writer.isRunning {
                writer.terminate()
            }
            writer.waitUntilExit()
        }
        try writerInput.fileHandleForWriting.write(contentsOf: Data("""
        PRAGMA journal_mode = WAL;
        PRAGMA wal_autocheckpoint = 0;
        CREATE TABLE records (value TEXT NOT NULL);
        INSERT INTO records VALUES ('uncheckpointed');

        """.utf8))

        let walPath = sourceURL.path + "-wal"
        var writerIsReady = false
        let readyDeadline = Date().addingTimeInterval(2)
        while Date() < readyDeadline {
            if (try? scalarInt(sourceURL, "SELECT COUNT(*) FROM records")) == 1 {
                writerIsReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(writerIsReady)
        try #require(FileManager.default.fileExists(atPath: walPath))

        try SQLiteDatabaseSnapshotService().copyDatabase(
            from: sourceURL.path,
            to: snapshotURL.path
        )

        #expect(
            try scalarInt(snapshotURL, "SELECT COUNT(*) FROM records") == 1
        )
    }

    @Test("Online backup has a total deadline despite intermittent progress")
    func onlineBackupDeadlineSurvivesProgressAndSourceWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("live.db", isDirectory: false)
        let snapshotURL = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeLargeWALDatabase(at: sourceURL)

        let maximumDuration = Duration.seconds(10)
        var instant = ContinuousClock().now
        let service = SQLiteDatabaseSnapshotService(
            pagesPerStep: 1,
            maximumDuration: maximumDuration,
            now: { instant },
            stepObserver: {
                try exec(sourceURL, "UPDATE records SET generation = generation + 1")
                instant = instant.advanced(by: maximumDuration)
            }
        )

        #expect(
            throws: SQLiteDatabaseSnapshotError.timedOut(
                maximumDuration: maximumDuration
            )
        ) {
            try service.copyDatabase(
                from: sourceURL.path,
                to: snapshotURL.path
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try #require(value as? NSNumber).intValue & 0o777
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

    private func makeLargeWALDatabase(at url: URL) throws {
        try exec(url, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE records (
          id INTEGER PRIMARY KEY,
          generation INTEGER NOT NULL,
          payload TEXT NOT NULL
        );
        WITH RECURSIVE rows(id) AS (
          SELECT 1
          UNION ALL
          SELECT id + 1 FROM rows WHERE id < 512
        )
        INSERT INTO records (id, generation, payload)
        SELECT id, 1, hex(randomblob(2048)) FROM rows;
        """)
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }

    private func scalarInt(_ dbURL: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw HermesAgentIndexError.sqlite(
                sqlite3_errmsg(db).map { String(cString: $0) } ?? "prepare failed"
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HermesAgentIndexError.sqlite("step failed")
        }
        return sqlite3_column_int64(statement, 0)
    }
}
