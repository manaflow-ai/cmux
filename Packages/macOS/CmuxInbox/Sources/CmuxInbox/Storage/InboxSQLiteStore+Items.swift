import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Inserts or updates an item, deduping by source account and external message id.
    /// - Parameter item: Item to persist.
    public func upsertItem(_ item: InboxItem) throws {
        try database.transaction {
            try database.exec("""
            INSERT INTO items (
                item_id, thread_id, source, account_id, external_message_id,
                sender_name, sender_address, timestamp, body_preview, body,
                metadata_json, unread, actionable, draft_id, external_url
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, account_id, external_message_id) DO UPDATE SET
                item_id = excluded.item_id,
                thread_id = excluded.thread_id,
                sender_name = excluded.sender_name,
                sender_address = excluded.sender_address,
                timestamp = excluded.timestamp,
                body_preview = excluded.body_preview,
                body = excluded.body,
                metadata_json = excluded.metadata_json,
                unread = excluded.unread,
                actionable = excluded.actionable,
                draft_id = excluded.draft_id,
                external_url = excluded.external_url;
            """, binding: itemBindings(item))
            try refreshThreadUnreadCount(item.threadID)
            try upsertFTS(item)
        }
    }

    /// Inserts or updates a batch of items.
    /// - Parameter items: Items to persist.
    public func upsertItems(_ items: [InboxItem]) throws {
        for item in items {
            try upsertItem(item)
        }
    }

    /// Lists items with their threads according to the supplied query.
    /// - Parameter query: Query options.
    /// - Returns: Matching items.
    public func list(_ query: InboxListQuery) throws -> [InboxItem] {
        var clauses: [String] = []
        var bindings: [InboxDatabase.BindValue] = []
        if let source = query.source {
            clauses.append("items.source = ?")
            bindings.append(.text(source.rawValue))
        }
        if !query.includeArchived {
            clauses.append("threads.archived = 0")
        }
        switch query.filter {
        case .actionable:
            clauses.append("items.actionable = 1")
        case .unread:
            clauses.append("items.unread = 1")
        case .all:
            break
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        bindings.append(.int(Int64(query.limit)))
        let statement = try database.prepare("""
        SELECT items.item_id, items.thread_id, items.source, items.account_id,
               items.external_message_id, items.sender_name, items.sender_address,
               items.timestamp, items.body_preview, items.body, items.metadata_json,
               items.unread, items.actionable, items.draft_id, items.external_url
        FROM items
        JOIN threads ON threads.thread_id = items.thread_id
        \(whereSQL)
        ORDER BY items.actionable DESC, items.unread DESC, items.timestamp DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: bindings)
        return try itemRows(statement)
    }

    /// Returns recent context items for a thread.
    /// - Parameters:
    ///   - threadID: Local thread id.
    ///   - limit: Maximum context count.
    public func recentItems(threadID: String, limit: Int = 20) throws -> [InboxItem] {
        let statement = try database.prepare("""
        SELECT item_id, thread_id, source, account_id, external_message_id,
               sender_name, sender_address, timestamp, body_preview, body,
               metadata_json, unread, actionable, draft_id, external_url
        FROM items
        WHERE thread_id = ?
        ORDER BY timestamp DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(threadID), .int(Int64(max(1, min(limit, 100))))])
        return try itemRows(statement).reversed()
    }

    func item(from statement: OpaquePointer?) throws -> InboxItem {
        let source = InboxSource(rawValue: stringFromColumn(statement, 2)) ?? .generic
        let metadata = try decodeJSON([String: String].self, from: stringFromColumn(statement, 10))
        return InboxItem(
            itemID: stringFromColumn(statement, 0),
            threadID: stringFromColumn(statement, 1),
            source: source,
            accountID: stringFromColumn(statement, 3),
            externalMessageID: stringFromColumn(statement, 4),
            sender: InboxParticipant(
                displayName: stringFromColumn(statement, 5),
                address: optionalStringFromColumn(statement, 6)
            ),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            bodyPreview: stringFromColumn(statement, 8),
            body: optionalStringFromColumn(statement, 9),
            metadata: metadata,
            isUnread: sqlite3_column_int(statement, 11) != 0,
            isActionable: sqlite3_column_int(statement, 12) != 0,
            draftID: optionalStringFromColumn(statement, 13),
            externalURL: optionalStringFromColumn(statement, 14)
        )
    }

    private func itemBindings(_ item: InboxItem) throws -> [InboxDatabase.BindValue] {
        [
            .text(item.itemID),
            .text(item.threadID),
            .text(item.source.rawValue),
            .text(item.accountID),
            .text(item.externalMessageID),
            .text(item.sender.displayName),
            item.sender.address.map { .text($0) } ?? .null,
            .real(item.timestamp.timeIntervalSince1970),
            .text(item.bodyPreview),
            item.body.map { .text($0) } ?? .null,
            .text(try encodeJSON(item.metadata)),
            .int(item.isUnread ? 1 : 0),
            .int(item.isActionable ? 1 : 0),
            item.draftID.map { .text($0) } ?? .null,
            item.externalURL.map { .text($0) } ?? .null,
        ]
    }

    private func itemRows(_ statement: OpaquePointer?) throws -> [InboxItem] {
        var rows: [InboxItem] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
            rows.append(try item(from: statement))
        }
        return rows
    }
}
