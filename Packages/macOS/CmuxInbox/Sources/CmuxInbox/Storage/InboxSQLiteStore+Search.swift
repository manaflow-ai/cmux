import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Searches the local inbox full-text index.
    /// - Parameters:
    ///   - rawQuery: User-entered search query.
    ///   - limit: Maximum hit count.
    /// - Returns: Ranked search hits.
    public func search(_ rawQuery: String, limit: Int = 50) throws -> [InboxSearchHit] {
        let query = Self.ftsQuery(rawQuery)
        guard !query.isEmpty else { return [] }
        let statement = try database.prepare("""
        SELECT f.item_id,
               snippet(inbox_items_fts, 6, '[', ']', '...', 12),
               bm25(inbox_items_fts)
        FROM inbox_items_fts f
        WHERE inbox_items_fts MATCH ?
        ORDER BY bm25(inbox_items_fts)
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(query), .int(Int64(max(1, min(limit, 100))))])
        var hits: [InboxSearchHit] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
            let itemID = stringFromColumn(statement, 0)
            guard let item = try item(id: itemID), let thread = try thread(id: item.threadID) else { continue }
            hits.append(InboxSearchHit(
                item: item,
                thread: thread,
                snippet: stringFromColumn(statement, 1),
                rank: sqlite3_column_double(statement, 2)
            ))
        }
        return hits
    }

    func upsertFTS(_ item: InboxItem) throws {
        let title = try thread(id: item.threadID)?.title ?? ""
        try database.exec("DELETE FROM inbox_items_fts WHERE item_id = ?;", binding: [.text(item.itemID)])
        try database.exec("""
        INSERT INTO inbox_items_fts (item_id, thread_id, source, account_id, sender, title, body_preview, body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, binding: [
            .text(item.itemID),
            .text(item.threadID),
            .text(item.source.rawValue),
            .text(item.accountID),
            .text(item.sender.displayName),
            .text(title),
            .text(item.bodyPreview),
            .text(item.body ?? ""),
        ])
    }

    private static func ftsQuery(_ raw: String) -> String {
        raw
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }
}
