import Foundation
import SQLite3
import Testing

@testable import CMUXAgentLaunch

/// Regression coverage for `CodexNativeTitleStore` (cmux #11144): Codex's own
/// natively-generated thread title, read from a `state_5.sqlite` fixture.
struct CodexNativeTitleStoreTests {
    private enum FixtureError: Error { case database }

    /// Builds a minimal `state_5.sqlite`-shaped `threads` table with one row.
    /// Safe to call again against the same `url` to insert additional rows —
    /// `CREATE TABLE IF NOT EXISTS` leaves an already-created table alone.
    private func makeStateDatabase(at url: URL, sessionId: String, title: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw FixtureError.database
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                approval_mode TEXT NOT NULL,
                sandbox_policy TEXT NOT NULL,
                first_user_message TEXT NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.database
        }

        let insert = """
            INSERT INTO threads (
                id, rollout_path, cwd, title, approval_mode, sandbox_policy, first_user_message, archived
            ) VALUES (?, '/tmp/rollout.jsonl', '/tmp/project', ?, 'never', '{"type":"read-only"}', 'hi', 0);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw FixtureError.database
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, transient)
        sqlite3_bind_text(stmt, 2, title, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FixtureError.database
        }
    }

    @Test func readsNativeTitleForKnownSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-title-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("state_5.sqlite")
        try makeStateDatabase(at: dbURL, sessionId: "codex-native-title-session", title: "測試 cmux 與 codex Tab 同步")

        let title = CodexNativeTitleStore.title(forSessionId: "codex-native-title-session", dbPath: dbURL.path)
        #expect(title == "測試 cmux 與 codex Tab 同步")
    }

    @Test func returnsNilForUnknownSessionEmptyTitleOrMissingDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-title-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("state_5.sqlite")
        try makeStateDatabase(at: dbURL, sessionId: "known-session", title: "some title")
        try makeStateDatabase(at: dbURL, sessionId: "empty-title-session", title: "")

        // Unknown session id in an existing database.
        #expect(CodexNativeTitleStore.title(forSessionId: "unknown-session", dbPath: dbURL.path) == nil)

        // A row whose title is the empty string is treated the same as absent.
        #expect(CodexNativeTitleStore.title(forSessionId: "empty-title-session", dbPath: dbURL.path) == nil)

        // No database at the given path at all.
        let missingDB = dir.appendingPathComponent("does-not-exist.sqlite")
        #expect(CodexNativeTitleStore.title(forSessionId: "known-session", dbPath: missingDB.path) == nil)

        // Empty session id is rejected before touching disk.
        #expect(CodexNativeTitleStore.title(forSessionId: "", dbPath: dbURL.path) == nil)
    }
}
