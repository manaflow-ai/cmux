import Foundation
import SQLite3

/// Reads Codex's authoritative native thread title from its state database.
public struct CodexNativeTitleStore: Sendable {
    private let databasePath: String

    /// Creates a title store for the Codex profile at `codexHome`.
    public init(codexHome: String? = nil) {
        self.databasePath = Self.databasePath(forCodexHome: codexHome)
    }

    /// Creates a title store for a database path.
    ///
    /// This initializer is internal so production callers select a Codex home,
    /// while package tests can inject deterministic SQLite fixtures.
    init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// Returns the non-empty title for an active session, or nil when Codex's
    /// database, session row, or title is unavailable.
    public func title(forSessionId sessionId: String) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var statement: OpaquePointer?
        let query = "SELECT title FROM threads WHERE id = ?1 AND archived = 0 LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, normalizedSessionId, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let titleBytes = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let title = String(cString: titleBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Builds the state-database path for a Codex home directory.
    private static func databasePath(forCodexHome codexHome: String?) -> String {
        let home = (codexHome ?? "~/.codex") as NSString
        return URL(fileURLWithPath: home.expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path
    }
}
