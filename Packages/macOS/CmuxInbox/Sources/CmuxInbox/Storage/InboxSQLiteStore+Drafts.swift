import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Creates and stores a local draft for a thread.
    /// - Parameters:
    ///   - threadID: Local target thread id.
    ///   - instruction: Optional user instruction.
    ///   - body: Draft body shown before approval.
    public func createDraft(threadID: String, instruction: String?, body: String) throws -> InboxDraft {
        guard let thread = try thread(id: threadID) else { throw InboxError.notFound("Inbox thread not found") }
        let now = Date.now
        let draft = InboxDraft(
            draftID: InboxIdentity().draftID(threadID: threadID, createdAt: now),
            threadID: threadID,
            source: thread.source,
            accountID: thread.accountID,
            instruction: instruction,
            body: body,
            createdAt: now
        )
        try upsertDraft(draft)
        return draft
    }

    /// Inserts or updates a draft.
    /// - Parameter draft: Draft to persist.
    public func upsertDraft(_ draft: InboxDraft) throws {
        try database.exec("""
        INSERT INTO drafts (
            draft_id, thread_id, source, account_id, instruction, body, status,
            created_at, approved_at, sent_at, error_message
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(draft_id) DO UPDATE SET
            instruction = excluded.instruction,
            body = excluded.body,
            status = excluded.status,
            approved_at = excluded.approved_at,
            sent_at = excluded.sent_at,
            error_message = excluded.error_message;
        """, binding: [
            .text(draft.draftID),
            .text(draft.threadID),
            .text(draft.source.rawValue),
            .text(draft.accountID),
            draft.instruction.map { .text($0) } ?? .null,
            .text(draft.body),
            .text(draft.status.rawValue),
            .real(draft.createdAt.timeIntervalSince1970),
            sqliteDate(draft.approvedAt),
            sqliteDate(draft.sentAt),
            draft.errorMessage.map { .text($0) } ?? .null,
        ])
    }

    /// Looks up a draft by id.
    /// - Parameter draftID: Local draft id.
    /// - Returns: Draft when present.
    public func draft(id draftID: String) throws -> InboxDraft? {
        let statement = try database.prepare("""
        SELECT draft_id, thread_id, source, account_id, instruction, body,
               status, created_at, approved_at, sent_at, error_message
        FROM drafts
        WHERE draft_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(draftID)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
        return draft(from: statement)
    }

    func draft(from statement: OpaquePointer?) -> InboxDraft {
        InboxDraft(
            draftID: stringFromColumn(statement, 0),
            threadID: stringFromColumn(statement, 1),
            source: InboxSource(rawValue: stringFromColumn(statement, 2)) ?? .generic,
            accountID: stringFromColumn(statement, 3),
            instruction: optionalStringFromColumn(statement, 4),
            body: stringFromColumn(statement, 5),
            status: InboxDraftStatus(rawValue: stringFromColumn(statement, 6)) ?? .failed,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            approvedAt: dateFromColumn(statement, 8),
            sentAt: dateFromColumn(statement, 9),
            errorMessage: optionalStringFromColumn(statement, 10)
        )
    }
}
