import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Stores a connector sync cursor.
    /// - Parameters:
    ///   - cursor: Source cursor or nil to clear.
    ///   - source: Source service.
    ///   - accountID: Source account id.
    public func setSyncCursor(_ cursor: String?, source: InboxSource, accountID: String) throws {
        try database.exec("""
        INSERT INTO sync_state (source, account_id, cursor, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(source, account_id) DO UPDATE SET
            cursor = excluded.cursor,
            updated_at = excluded.updated_at;
        """, binding: [
            .text(source.rawValue),
            .text(accountID),
            cursor.map { .text($0) } ?? .null,
            .real(Date.now.timeIntervalSince1970),
        ])
    }

    /// Reads a connector sync cursor.
    /// - Parameters:
    ///   - source: Source service.
    ///   - accountID: Source account id.
    public func syncCursor(source: InboxSource, accountID: String) throws -> String? {
        let statement = try database.prepare("SELECT cursor FROM sync_state WHERE source = ? AND account_id = ?;")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(source.rawValue), .text(accountID)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
        return optionalStringFromColumn(statement, 0)
    }
}
