import CMUXAgentVault
import Foundation
import SQLite3
import Testing

@Suite("OpenCodeIndex")
struct OpenCodeIndexTests {
    @Test("Loads sessions sorted by update time with assistant metadata")
    func loadsSessionsSortedByUpdateTimeWithAssistantMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db", isDirectory: false)
        try makeOpenCodeDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO session (id, title, directory, time_updated)
        VALUES
          ('old-session', 'Old title', '/tmp/old', 1000),
          ('new-session', 'New title', '/tmp/new', 2000);
        INSERT INTO message (id, session_id, data, time_created)
        VALUES
          ('m1', 'new-session', '{"role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4","agent":"build"}', 2100);
        """)

        let result = OpenCodeIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            databasePath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["new-session", "old-session"])
        #expect(result.sessions.first?.providerModel == "anthropic/claude-sonnet-4")
        #expect(result.sessions.first?.agentName == "build")
        #expect(result.sessions.first?.modified == Date(timeIntervalSince1970: 2))
    }

    @Test("Filters by needle and exact cwd")
    func filtersByNeedleAndExactCwd() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db", isDirectory: false)
        try makeOpenCodeDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO session (id, title, directory, time_updated)
        VALUES
          ('matching-session', 'Needle title', '/tmp/repo', 2000),
          ('wrong-cwd', 'Needle title', '/tmp/other', 3000),
          ('wrong-title', 'Other title', '/tmp/repo', 4000);
        """)

        let result = OpenCodeIndex.loadSessions(
            needle: "needle",
            cwdFilter: "/tmp/repo",
            offset: 0,
            limit: 10,
            databasePath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["matching-session"])
    }

    @Test("Rejects invalid pagination inputs")
    func rejectsInvalidPaginationInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db", isDirectory: false)
        try makeOpenCodeDB(at: dbURL)

        let negativeOffset = OpenCodeIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: -1,
            limit: 10,
            databasePath: dbURL.path
        )
        let zeroLimit = OpenCodeIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 0,
            databasePath: dbURL.path
        )

        #expect(negativeOffset.sessions.isEmpty)
        #expect(negativeOffset.errors.isEmpty)
        #expect(zeroLimit.sessions.isEmpty)
        #expect(zeroLimit.errors.isEmpty)
    }

    @Test("Reports unsupported schema")
    func reportsUnsupportedSchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db", isDirectory: false)
        try exec(dbURL, "CREATE TABLE unrelated (id TEXT);")

        let result = OpenCodeIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            databasePath: dbURL.path
        )

        #expect(result.sessions.isEmpty)
        #expect(result.errors.count == 1)
        #expect(result.errors[0] == "OpenCode session history is unavailable in this version.")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeOpenCodeDB(at url: URL) throws {
        try exec(url, """
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          title TEXT,
          directory TEXT,
          time_updated INTEGER NOT NULL
        );
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          data TEXT,
          time_created INTEGER NOT NULL
        );
        """)
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw OpenCodeTestError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw OpenCodeTestError.sqlite(message)
        }
    }
}

private enum OpenCodeTestError: Error {
    case sqlite(String)
}
