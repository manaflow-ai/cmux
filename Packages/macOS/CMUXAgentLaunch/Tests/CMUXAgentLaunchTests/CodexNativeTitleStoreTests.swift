import Foundation
import SQLite3
import Testing

@testable import CMUXAgentLaunch

struct CodexNativeTitleStoreTests {
    private enum FixtureError: Error {
        case database
    }

    /// Reads the title associated with the requested Codex session only.
    @Test func readsTheNativeThreadTitleForAnExactSession() throws {
        let fixture = try makeDatabase(sessionId: "codex-session", title: "測試 cmux 與 codex Tab 同步")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = CodexNativeTitleStore(databasePath: fixture.database.path)
        #expect(store.title(forSessionId: fixture.sessionId) == "測試 cmux 與 codex Tab 同步")
    }

    /// Returns no title for missing, empty, or unavailable session data.
    @Test(arguments: ["missing-session", ""])
    func returnsNilWhenTheTitleCannotBeResolved(sessionId: String) throws {
        let fixture = try makeDatabase(sessionId: "codex-session", title: "existing title")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = CodexNativeTitleStore(databasePath: fixture.database.path)
        #expect(store.title(forSessionId: sessionId) == nil)
        let missingDatabase = fixture.directory.appendingPathComponent("missing.sqlite")
        let missingStore = CodexNativeTitleStore(databasePath: missingDatabase.path)
        #expect(missingStore.title(forSessionId: sessionId) == nil)
    }

    /// Creates a temporary SQLite database that mirrors the Codex thread table.
    private func makeDatabase(sessionId: String, title: String) throws -> (directory: URL, database: URL, sessionId: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-title-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state_5.sqlite")

        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else {
            throw FixtureError.database
        }
        defer { sqlite3_close(connection) }

        let schema = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            )
            """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.database
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "INSERT INTO threads (id, title) VALUES (?1, ?2)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FixtureError.database
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionId, -1, transient)
        sqlite3_bind_text(statement, 2, title, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.database }
        return (directory, database, sessionId)
    }
}
