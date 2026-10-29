@testable import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

@Suite("MuseSessionIndex")
struct MuseSessionIndexTests {
    @Test("Lists resumable top-level sessions newest first")
    func listsTopLevelSessionsNewestFirst() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = try makeIndex(in: root)

        let result = MuseSessionIndex(indexDatabasePath: dbURL.path).loadSessions(
            needle: "", cwdFilter: nil, offset: 0, limit: 10
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["tui-new", "exec-old"])
        let newest = try #require(result.sessions.first)
        #expect(newest.title == "Fix the build")
        #expect(newest.cwd == "/work/app")
        #expect(newest.gitBranch == "main")
        #expect(newest.modified == Date(timeIntervalSince1970: 1_700_000_200))
    }

    @Test("Filters by needle, working directory, and page")
    func filtersByNeedleCwdAndPage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = try makeIndex(in: root)

        let byNeedle = MuseSessionIndex(indexDatabasePath: dbURL.path).loadSessions(
            needle: "FLAKY", cwdFilter: nil, offset: 0, limit: 10
        )
        #expect(byNeedle.sessions.map(\.sessionId) == ["exec-old"])

        let byCwd = MuseSessionIndex(indexDatabasePath: dbURL.path).loadSessions(
            needle: "", cwdFilter: "/work/other", offset: 0, limit: 10
        )
        #expect(byCwd.sessions.map(\.sessionId) == ["exec-old"])

        let secondPage = MuseSessionIndex(indexDatabasePath: dbURL.path).loadSessions(
            needle: "", cwdFilter: nil, offset: 1, limit: 1
        )
        #expect(secondPage.sessions.map(\.sessionId) == ["exec-old"])
    }

    @Test("Missing index is empty, not an error")
    func missingIndexIsEmpty() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = MuseSessionIndex(indexDatabasePath: root.appendingPathComponent("session-index.db").path).loadSessions(
            needle: "", cwdFilter: nil, offset: 0, limit: 10
        )
        #expect(result == MuseSessionIndexResult(sessions: [], errors: []))
    }

    @Test("Data directory honors XDG_DATA_HOME")
    func dataDirectoryHonorsXDG() {
        #expect(MuseSessionIndex.defaultDataDirectory(env: [:], homeDirectory: "/Users/me") == "/Users/me/.local/share/muse")
        #expect(MuseSessionIndex.defaultDataDirectory(env: ["XDG_DATA_HOME": "/data"], homeDirectory: "/Users/me") == "/data/muse")
    }

    private func makeIndex(in root: URL) throws -> URL {
        let dbURL = root.appendingPathComponent("session-index.db", isDirectory: false)
        try exec(dbURL, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY,
          workspace_root TEXT,
          git_branch TEXT,
          title TEXT,
          session_name TEXT,
          first_user_prompt TEXT,
          search_text TEXT,
          prompt_count INTEGER,
          updated_at_us INTEGER,
          msp_kind TEXT,
          msp_parent_session_id TEXT
        );
        INSERT INTO sessions VALUES
          ('exec-old', '/work/other', NULL, 'flaky test', NULL, 'flaky test', 'flaky test', 1, 1700000100000000, 'root', NULL),
          ('tui-new', '/work/app', 'main', 'Fix the build', NULL, 'fix the build', 'fix the build', 2, 1700000200000000, NULL, NULL),
          ('empty', '/work/app', NULL, 'New session', NULL, NULL, NULL, 0, 1700000300000000, NULL, NULL),
          ('child', '/work/app', NULL, 'reminder', NULL, 'reminder', NULL, 1, 1700000400000000, 'subagent', 'tui-new');
        """)
        return dbURL
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-muse-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }
}
