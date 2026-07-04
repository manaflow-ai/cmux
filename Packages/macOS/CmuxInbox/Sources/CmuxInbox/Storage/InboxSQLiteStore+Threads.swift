import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Inserts or updates a thread.
    /// - Parameter thread: Thread to persist.
    public func upsertThread(_ thread: InboxThread) throws {
        try database.exec("""
        INSERT INTO threads (
            thread_id, source, account_id, external_thread_id, participants_json,
            title, unread_count, last_activity_at, muted, pinned, archived,
            external_url, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, account_id, external_thread_id) DO UPDATE SET
            thread_id = excluded.thread_id,
            participants_json = excluded.participants_json,
            title = excluded.title,
            last_activity_at = MAX(threads.last_activity_at, excluded.last_activity_at),
            muted = excluded.muted,
            pinned = excluded.pinned,
            archived = excluded.archived,
            external_url = excluded.external_url,
            metadata_json = excluded.metadata_json;
        """, binding: [
            .text(thread.threadID),
            .text(thread.source.rawValue),
            .text(thread.accountID),
            .text(thread.externalThreadID),
            .text(try encodeJSON(thread.participants)),
            .text(thread.title),
            .int(Int64(thread.unreadCount)),
            .real(thread.lastActivityAt.timeIntervalSince1970),
            .int(thread.isMuted ? 1 : 0),
            .int(thread.isPinned ? 1 : 0),
            .int(thread.isArchived ? 1 : 0),
            thread.externalURL.map { .text($0) } ?? .null,
            .text(try encodeJSON(thread.metadata)),
        ])
        try refreshThreadUnreadCount(thread.threadID)
    }

    /// Looks up a thread by local id.
    /// - Parameter threadID: Local thread id.
    /// - Returns: Thread when present.
    public func thread(id threadID: String) throws -> InboxThread? {
        let statement = try database.prepare("""
        SELECT thread_id, source, account_id, external_thread_id, participants_json,
               title, unread_count, last_activity_at, muted, pinned, archived,
               external_url, metadata_json
        FROM threads
        WHERE thread_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(threadID)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
        return try thread(from: statement)
    }

    /// Looks up threads by local ids.
    /// - Parameter threadIDs: Local thread ids to load.
    /// - Returns: Threads matching the requested ids.
    public func threads(ids threadIDs: [String]) throws -> [InboxThread] {
        let uniqueIDs = Array(Set(threadIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ", ")
        let statement = try database.prepare("""
        SELECT thread_id, source, account_id, external_thread_id, participants_json,
               title, unread_count, last_activity_at, muted, pinned, archived,
               external_url, metadata_json
        FROM threads
        WHERE thread_id IN (\(placeholders));
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: uniqueIDs.map { .text($0) })
        var rows: [InboxThread] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
            rows.append(try thread(from: statement))
        }
        return rows
    }

    func refreshThreadUnreadCount(_ threadID: String) throws {
        try database.exec("""
        UPDATE threads
        SET unread_count = (
            SELECT COUNT(*) FROM items WHERE items.thread_id = threads.thread_id AND unread = 1
        ),
        last_activity_at = MAX(
            last_activity_at,
            COALESCE((SELECT MAX(timestamp) FROM items WHERE items.thread_id = threads.thread_id), last_activity_at)
        )
        WHERE thread_id = ?;
        """, binding: [.text(threadID)])
    }

    func thread(from statement: OpaquePointer?) throws -> InboxThread {
        let source = InboxSource(rawValue: stringFromColumn(statement, 1)) ?? .generic
        let participants = try decodeJSON([InboxParticipant].self, from: stringFromColumn(statement, 4))
        let metadata = try decodeJSON([String: String].self, from: stringFromColumn(statement, 12))
        return InboxThread(
            threadID: stringFromColumn(statement, 0),
            source: source,
            accountID: stringFromColumn(statement, 2),
            externalThreadID: stringFromColumn(statement, 3),
            participants: participants,
            title: stringFromColumn(statement, 5),
            unreadCount: Int(sqlite3_column_int64(statement, 6)),
            lastActivityAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            isMuted: sqlite3_column_int(statement, 8) != 0,
            isPinned: sqlite3_column_int(statement, 9) != 0,
            isArchived: sqlite3_column_int(statement, 10) != 0,
            externalURL: optionalStringFromColumn(statement, 11),
            metadata: metadata
        )
    }
}
