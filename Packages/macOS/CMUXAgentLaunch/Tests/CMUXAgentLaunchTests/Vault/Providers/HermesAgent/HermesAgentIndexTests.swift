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

    @Test("Searches messages and excludes NULL-cwd rows from a directory-scoped request")
    func searchesMessagesAndExcludesNullCwdFromScopedRequests() throws {
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
        // session-a has no cwd recorded, so a directory-scoped request must not return it.
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

    @Test("cwd-scoped loadSessions returns the newest matching cli/tui session, newest first")
    func loadSessionsCwdFilterReturnsNewestMatchingSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        let repoA = try makeDirectory(root.appendingPathComponent("repo-a", isDirectory: true))
        let repoB = try makeDirectory(root.appendingPathComponent("repo-b", isDirectory: true))
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, cwd, title)
        VALUES
          ('a-old', 'cli', 'model-a', 10, '\(repoA)', 'A old'),
          ('a-new', 'tui', 'model-b', 30, '\(repoA)', 'A new'),
          ('b-newest', 'cli', 'model-c', 99, '\(repoB)', 'B newest');
        """)

        let scoped = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: repoA,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(scoped.errors.isEmpty)
        // Only repo-a sessions, newest first; the globally-newest repo-b session must NOT leak in.
        #expect(scoped.sessions.map(\.sessionId) == ["a-new", "a-old"])
    }

    @Test("latestSessionID returns the newest session for a cwd and never another cwd's session")
    func latestSessionIDReturnsNewestSessionScopedToCwd() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        let repoA = try makeDirectory(root.appendingPathComponent("repo-a", isDirectory: true))
        let repoB = try makeDirectory(root.appendingPathComponent("repo-b", isDirectory: true))
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, cwd)
        VALUES
          ('a-old', 'cli', 'model-a', 10, '\(repoA)'),
          ('a-new', 'tui', 'model-b', 50, '\(repoA)'),
          ('b-newest-globally', 'cli', 'model-c', 999, '\(repoB)');
        """)

        #expect(HermesAgentIndex.latestSessionID(cwd: repoA, stateDBPath: dbURL.path) == "a-new")
        #expect(HermesAgentIndex.latestSessionID(cwd: repoB, stateDBPath: dbURL.path) == "b-newest-globally")
    }

    @Test("latestSessionID and cwd filter exclude gateway sources and NULL-cwd rows")
    func cwdScopedLookupExcludesGatewayAndNullCwd() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        let repo = try makeDirectory(root.appendingPathComponent("repo", isDirectory: true))
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, cwd)
        VALUES
          ('gateway', 'telegram', 'model-a', 100, '\(repo)'),
          ('null-cwd', 'cli', 'model-b', 90, NULL),
          ('interactive', 'cli', 'model-c', 20, '\(repo)');
        """)

        // The gateway row (newest) and NULL-cwd row must be ignored; only the cli row for the cwd wins.
        #expect(HermesAgentIndex.latestSessionID(cwd: repo, stateDBPath: dbURL.path) == "interactive")
        let scoped = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: repo,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )
        #expect(scoped.sessions.map(\.sessionId) == ["interactive"])
    }

    @Test("latestSessionID matches a cwd reached through a symlink")
    func latestSessionIDMatchesThroughSymlink() throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        let realDir = try makeDirectory(root.appendingPathComponent("real-repo", isDirectory: true), returningResolved: false)
        let aliasURL = root.appendingPathComponent("alias-repo", isDirectory: false)
        try fm.createSymbolicLink(at: aliasURL, withDestinationURL: URL(fileURLWithPath: realDir, isDirectory: true))
        // Hermes stores os.getcwd(), i.e. the fully symlink-resolved path.
        let storedCwd = URL(fileURLWithPath: realDir).resolvingSymlinksInPath().path
        try exec(dbURL, """
        INSERT INTO sessions (id, source, started_at, cwd)
        VALUES ('through-symlink', 'cli', 10, '\(storedCwd)');
        """)

        // Querying via the symlinked path still resolves to the stored realpath.
        #expect(HermesAgentIndex.latestSessionID(cwd: aliasURL.path, stateDBPath: dbURL.path) == "through-symlink")
    }

    @Test("latestSessionID returns nil for an unmatched cwd or a missing database")
    func latestSessionIDReturnsNilForNoMatchOrMissingDB() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        let repo = try makeDirectory(root.appendingPathComponent("repo", isDirectory: true))
        try exec(dbURL, """
        INSERT INTO sessions (id, source, started_at, cwd)
        VALUES ('only', 'cli', 10, '\(repo)');
        """)

        #expect(HermesAgentIndex.latestSessionID(cwd: root.appendingPathComponent("other").path, stateDBPath: dbURL.path) == nil)
        #expect(HermesAgentIndex.latestSessionID(cwd: repo, stateDBPath: root.appendingPathComponent("missing.db").path) == nil)
        #expect(HermesAgentIndex.latestSessionID(cwd: "   ", stateDBPath: dbURL.path) == nil)
    }

    @Test("canonicalCwd collapses a symlinked path and its real path to one value")
    func canonicalCwdCollapsesSymlinkAndRealPath() throws {
        let fm = FileManager.default
        let root = try temporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let realDir = root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let aliasURL = root.appendingPathComponent("alias", isDirectory: false)
        try fm.createSymbolicLink(at: aliasURL, withDestinationURL: realDir)

        let viaReal = HermesAgentIndex.canonicalCwd(realDir.path)
        let viaAlias = HermesAgentIndex.canonicalCwd(aliasURL.path)
        #expect(viaReal != nil)
        #expect(viaReal == viaAlias)
        #expect(HermesAgentIndex.canonicalCwd("   ") == nil)
    }

    private func makeDirectory(_ url: URL, returningResolved: Bool = false) throws -> String {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return returningResolved ? url.resolvingSymlinksInPath().path : url.path
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
          cwd TEXT,
          git_branch TEXT,
          git_repo_root TEXT,
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
