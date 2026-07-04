import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Marks an item or thread read or unread.
    /// - Parameters:
    ///   - itemID: Optional local item id.
    ///   - threadID: Optional local thread id.
    ///   - unread: New unread state.
    public func markRead(itemID: String? = nil, threadID: String? = nil, unread: Bool = false) throws {
        guard itemID != nil || threadID != nil else {
            throw InboxError.invalidParameters("markRead requires itemID or threadID")
        }
        try database.transaction {
            if let itemID {
                let threadStatement = try database.prepare("SELECT thread_id FROM items WHERE item_id = ?;")
                defer { sqlite3_finalize(threadStatement) }
                try database.bind(statement: threadStatement, parameters: [.text(itemID)])
                let step = sqlite3_step(threadStatement)
                guard step == SQLITE_ROW else { throw InboxError.notFound("Inbox item not found") }
                let resolvedThreadID = stringFromColumn(threadStatement, 0)
                try database.exec("UPDATE items SET unread = ? WHERE item_id = ?;", binding: [
                    .int(unread ? 1 : 0),
                    .text(itemID),
                ])
                try refreshThreadUnreadCount(resolvedThreadID)
            }
            if let threadID {
                try database.exec("UPDATE items SET unread = ? WHERE thread_id = ?;", binding: [
                    .int(unread ? 1 : 0),
                    .text(threadID),
                ])
                try refreshThreadUnreadCount(threadID)
            }
        }
    }

    /// Returns unread and actionable counts per source.
    /// - Returns: Source-level unread counts.
    public func unreadCounts() throws -> [InboxSourceUnreadCount] {
        let statement = try database.prepare("""
        SELECT source,
               SUM(CASE WHEN unread = 1 THEN 1 ELSE 0 END) AS unread_count,
               SUM(CASE WHEN actionable = 1 THEN 1 ELSE 0 END) AS actionable_count
        FROM items
        WHERE unread = 1 OR actionable = 1
        GROUP BY source
        ORDER BY source;
        """)
        defer { sqlite3_finalize(statement) }
        var counts: [InboxSourceUnreadCount] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
            let source = InboxSource(rawValue: stringFromColumn(statement, 0)) ?? .generic
            counts.append(InboxSourceUnreadCount(
                source: source,
                unreadCount: Int(sqlite3_column_int64(statement, 1)),
                actionableCount: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return counts
    }
}
