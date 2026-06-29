import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

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

    @Test("Searches messages by needle")
    func searchesMessagesByNeedle() throws {
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

        #expect(found.sessions.map(\.sessionId) == ["session-a"])
    }

    // Regression: cmux must be able to map a scanned hermes process to ITS
    // session (not the newest one globally) when several hermes panes/gateways
    // share one state.db. The disambiguator is the recorded `cwd`. Before this
    // fix, any non-nil cwdFilter returned [] (the index ignored cwd entirely),
    // so two concurrent panes would both bind to the global-newest session.
    @Test("Filters sessions by working directory, newest-per-cwd")
    func filtersSessionsByWorkingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        // Two panes (cwd A and cwd B) plus an older session in A. Globally newest
        // is in B; pane A must still resolve A's newest, never B's.
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES
          ('a-old', 'cli', 'm', 10, NULL, '/repo/alpha'),
          ('a-new', 'cli', 'm', 30, NULL, '/repo/alpha'),
          ('b-new', 'cli', 'm', 40, NULL, '/repo/beta');
        """)

        let alpha = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: "/repo/alpha", offset: 0, limit: 1, stateDBPath: dbURL.path
        )
        let beta = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: "/repo/beta", offset: 0, limit: 1, stateDBPath: dbURL.path
        )
        let global = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: nil, offset: 0, limit: 1, stateDBPath: dbURL.path
        )

        #expect(alpha.sessions.map(\.sessionId) == ["a-new"])   // not b-new (global newest)
        #expect(beta.sessions.map(\.sessionId) == ["b-new"])
        #expect(global.sessions.map(\.sessionId) == ["b-new"])  // unfiltered = global newest
        #expect(alpha.errors.isEmpty && beta.errors.isEmpty)
    }

    @Test("A cwd filter with no matching session yields nothing (never mis-binds)")
    func cwdFilterWithNoMatchYieldsNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        // A real session exists, but in a different cwd, and one with NULL cwd.
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES
          ('elsewhere', 'cli', 'm', 50, NULL, '/repo/elsewhere'),
          ('nullcwd', 'cli', 'm', 60, NULL, NULL);
        """)

        let result = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: "/repo/target", offset: 0, limit: 1, stateDBPath: dbURL.path
        )
        // Refuse to bind rather than fall back to the global-newest 'nullcwd' /
        // 'elsewhere' session — a missed resume is recoverable; a wrong one is not.
        #expect(result.sessions.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test("A NULL-cwd session never matches a non-nil cwd filter")
    func nullCwdNeverMatchesFilter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES ('nullcwd', 'cli', 'm', 60, NULL, NULL);
        """)

        let filtered = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: "/repo/target", offset: 0, limit: 5, stateDBPath: dbURL.path
        )
        let unfiltered = HermesAgentIndex.loadSessions(
            needle: "", cwdFilter: nil, offset: 0, limit: 5, stateDBPath: dbURL.path
        )

        #expect(filtered.sessions.isEmpty)
        #expect(unfiltered.sessions.map(\.sessionId) == ["nullcwd"])  // still visible unscoped
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
          title TEXT,
          api_call_count INTEGER DEFAULT 0,
          cwd TEXT
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
}
