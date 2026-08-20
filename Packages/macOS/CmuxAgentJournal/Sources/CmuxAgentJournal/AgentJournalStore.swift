public import Foundation
internal import SQLite3
internal import os

/// Append-only, durable store for semantic agent events.
///
/// Ported from the cmux-tui session journal's storage design: an append-only
/// SQLite table with a strictly monotonic `sequence` (AUTOINCREMENT, never
/// reused), immutability triggers that reject UPDATE/DELETE, WAL +
/// `synchronous=FULL` so an acknowledged append is durable, and idempotent
/// appends keyed by `event_id` so producer retries replay the original
/// receipt instead of double-writing.
///
/// The store also owns two small mutable sidecar tables (deliberately outside
/// the append-only contract): surface/workspace alias maps recorded during
/// session restore, so events journaled against a previous run's runtime panel
/// UUIDs can be re-attributed to the restored panels during replay.
///
/// Concurrency: all methods are synchronous and internally serialized by an
/// unfair lock. This is the sanctioned short-synchronous-critical-section
/// carve-out: the socket worker thread must produce the durable append
/// acknowledgement synchronously (its reply contract), so an actor hop is not
/// available there, and every guarded section is one bounded SQLite
/// transaction.
///
/// ```swift
/// let store = try AgentJournalStore(databaseURL: url)
/// let outcome = try store.append(draft)
/// let events = try store.events(afterSequence: 0, limit: 1024)
/// ```
public final class AgentJournalStore: @unchecked Sendable {
    /// Prune trigger: when the journal holds more than this many events at
    /// open, the oldest are pruned down to ``retainedEventCountAfterPrune``.
    public static let maximumEventCountAtOpen = 200_000
    /// Events retained by an open-time prune.
    public static let retainedEventCountAfterPrune = 100_000
    /// Longest alias chain follow before giving up (defends against cycles).
    public static let maximumAliasChainLength = 32

    // Lock justification: callers are the socket worker thread (which must
    // reply with the committed sequence synchronously) and the app's journal
    // consumer task; each guarded section is one bounded SQLite transaction.
    private let lock = OSAllocatedUnfairLock<AgentJournalDatabase?>(initialState: nil)

    /// Opens (creating and migrating as needed) the journal at `databaseURL`.
    ///
    /// - Parameter databaseURL: Location of the SQLite database file; parent
    ///   directories are created if missing.
    /// - Throws: ``AgentJournalStoreError`` when SQLite setup fails.
    public init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AgentJournalDatabase(path: databaseURL.path)
        do {
            try Self.migrate(database)
            try Self.pruneIfNeeded(database)
        } catch {
            database.close()
            throw error
        }
        lock.withLock { $0 = database }
    }

    /// Closes the underlying connection; later calls throw
    /// ``AgentJournalStoreError/closed``.
    public func close() {
        lock.withLock { database in
            database?.close()
            database = nil
        }
    }

    /// Appends one event, or replays the receipt of a previous append with
    /// the same `event_id`.
    ///
    /// - Parameters:
    ///   - draft: The event to append; validated via
    ///     ``AgentJournalEventDraft/validationProblem()``.
    ///   - committedAt: Commit timestamp source (injectable for tests).
    /// - Returns: The durable ``AgentJournalAppendOutcome``.
    /// - Throws: ``AgentJournalStoreError/invalidDraft(_:)`` for inadmissible
    ///   drafts, ``AgentJournalStoreError/idempotencyConflict(_:)`` when the
    ///   same event id arrives with different content, or a storage error.
    public func append(
        _ draft: AgentJournalEventDraft,
        committedAt: Date = Date()
    ) throws -> AgentJournalAppendOutcome {
        if let problem = draft.validationProblem() {
            throw AgentJournalStoreError.invalidDraft(problem)
        }
        let committedAtMs = Int64(committedAt.timeIntervalSince1970 * 1000)
        return try withDatabase { database in
            try database.transaction {
                if let existing = try Self.lookupByEventId(database, eventId: draft.eventId) {
                    guard existing.draft == draft else {
                        throw AgentJournalStoreError.idempotencyConflict(
                            "event id \(draft.eventId) was retried with different content"
                        )
                    }
                    return AgentJournalAppendOutcome(
                        sequence: existing.sequence,
                        committedAtMs: existing.committedAtMs,
                        replayed: true
                    )
                }
                try database.exec(
                    """
                    INSERT INTO agent_journal(
                        event_id, schema_version, kind, occurred_at_ms, committed_at_ms,
                        source, agent_key, session_id, workspace_id, surface_id,
                        unattributed_reason, is_subagent, pending_work, native_event,
                        declared_phase, detail
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16);
                    """,
                    binding: [
                        .text(draft.eventId),
                        .int(Int64(draft.schemaVersion)),
                        .text(draft.kind.rawValue),
                        .int(draft.occurredAtMs),
                        .int(committedAtMs),
                        .text(draft.source),
                        .text(draft.agentKey),
                        .optionalText(draft.sessionId),
                        .optionalText(draft.workspaceId),
                        .optionalText(draft.surfaceId),
                        .optionalText(draft.unattributedReason),
                        .int(draft.isSubagent ? 1 : 0),
                        .int(draft.pendingWork ? 1 : 0),
                        .optionalText(draft.nativeEvent),
                        .optionalText(draft.declaredPhase?.rawValue),
                        .optionalText(draft.detail),
                    ]
                )
                let sequence = try Self.scalarInt64(
                    database,
                    "SELECT sequence FROM agent_journal WHERE event_id = ?1;",
                    binding: [.text(draft.eventId)]
                ) ?? 0
                return AgentJournalAppendOutcome(
                    sequence: sequence,
                    committedAtMs: committedAtMs,
                    replayed: false
                )
            }
        }
    }

    /// Reads committed events in sequence order.
    ///
    /// - Parameters:
    ///   - afterSequence: Exclusive lower bound (pass 0 to read from the start).
    ///   - limit: Maximum number of events returned.
    /// - Returns: Events ordered by ascending sequence.
    /// - Throws: A storage error.
    public func events(afterSequence: Int64, limit: Int) throws -> [AgentJournalEvent] {
        try withDatabase { database in
            let statement = try database.prepare(
                """
                SELECT sequence, event_id, schema_version, kind, occurred_at_ms, committed_at_ms,
                       source, agent_key, session_id, workspace_id, surface_id,
                       unattributed_reason, is_subagent, pending_work, native_event,
                       declared_phase, detail
                FROM agent_journal WHERE sequence > ?1 ORDER BY sequence ASC LIMIT ?2;
                """
            )
            defer { sqlite3_finalize(statement) }
            try database.bind(statement: statement, parameters: [
                .int(afterSequence),
                .int(Int64(max(0, limit))),
            ])
            var results: [AgentJournalEvent] = []
            while database.step(statement) == SQLITE_ROW {
                guard let event = Self.decodeRow(database, statement) else { continue }
                results.append(event)
            }
            return results
        }
    }

    /// The highest committed sequence (0 when the journal is empty).
    ///
    /// - Returns: The head sequence.
    /// - Throws: A storage error.
    public func headSequence() throws -> Int64 {
        try withDatabase { database in
            try Self.scalarInt64(
                database,
                "SELECT COALESCE(MAX(sequence), 0) FROM agent_journal;",
                binding: []
            ) ?? 0
        }
    }

    /// Records identity aliases produced by a session restore, so events
    /// journaled against the previous run's runtime UUIDs re-attach to the
    /// restored panels during replay.
    ///
    /// - Parameters:
    ///   - workspaceAliases: Old workspace UUID string → new workspace UUID string.
    ///   - surfaceAliases: Old surface UUID string → new surface UUID string.
    /// - Throws: A storage error.
    public func recordRestoreAliases(
        workspaceAliases: [String: String],
        surfaceAliases: [String: String]
    ) throws {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty else { return }
        try withDatabase { database in
            try database.transaction {
                for (old, new) in workspaceAliases where old != new {
                    try database.exec(
                        "INSERT OR REPLACE INTO workspace_alias(old_workspace_id, new_workspace_id) VALUES (?1, ?2);",
                        binding: [.text(old), .text(new)]
                    )
                }
                for (old, new) in surfaceAliases where old != new {
                    try database.exec(
                        "INSERT OR REPLACE INTO surface_alias(old_surface_id, new_surface_id) VALUES (?1, ?2);",
                        binding: [.text(old), .text(new)]
                    )
                }
            }
        }
    }

    /// Resolves a surface UUID through the recorded alias chain to the most
    /// current identity.
    ///
    /// - Parameter surfaceId: The (possibly stale) surface UUID string.
    /// - Returns: The most current surface UUID string.
    /// - Throws: A storage error.
    public func resolvedSurfaceId(_ surfaceId: String) throws -> String {
        try resolveAlias(
            surfaceId,
            sql: "SELECT new_surface_id FROM surface_alias WHERE old_surface_id = ?1;"
        )
    }

    /// Resolves a workspace UUID through the recorded alias chain to the most
    /// current identity.
    ///
    /// - Parameter workspaceId: The (possibly stale) workspace UUID string.
    /// - Returns: The most current workspace UUID string.
    /// - Throws: A storage error.
    public func resolvedWorkspaceId(_ workspaceId: String) throws -> String {
        try resolveAlias(
            workspaceId,
            sql: "SELECT new_workspace_id FROM workspace_alias WHERE old_workspace_id = ?1;"
        )
    }

    private func resolveAlias(_ identifier: String, sql: String) throws -> String {
        try withDatabase { database in
            var current = identifier
            var hops = 0
            while hops < Self.maximumAliasChainLength {
                let statement = try database.prepare(sql)
                defer { sqlite3_finalize(statement) }
                try database.bind(statement: statement, parameters: [.text(current)])
                guard database.step(statement) == SQLITE_ROW,
                      let next = database.columnText(statement, 0),
                      next != current else {
                    return current
                }
                current = next
                hops += 1
            }
            return current
        }
    }

    private func withDatabase<Result>(
        _ body: (AgentJournalDatabase) throws -> Result
    ) throws -> Result {
        // withLockUnchecked: results are plain value types and the closure
        // only touches the lock-guarded connection; nothing escapes the
        // critical section.
        try lock.withLockUnchecked { database in
            guard let database else { throw AgentJournalStoreError.closed }
            return try body(database)
        }
    }

    private static func lookupByEventId(
        _ database: AgentJournalDatabase,
        eventId: String
    ) throws -> AgentJournalEvent? {
        let statement = try database.prepare(
            """
            SELECT sequence, event_id, schema_version, kind, occurred_at_ms, committed_at_ms,
                   source, agent_key, session_id, workspace_id, surface_id,
                   unattributed_reason, is_subagent, pending_work, native_event,
                   declared_phase, detail
            FROM agent_journal WHERE event_id = ?1;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(eventId)])
        guard database.step(statement) == SQLITE_ROW else { return nil }
        return decodeRow(database, statement)
    }

    private static func decodeRow(
        _ database: AgentJournalDatabase,
        _ statement: OpaquePointer?
    ) -> AgentJournalEvent? {
        guard let kindRaw = database.columnText(statement, 3),
              let kind = AgentJournalEventKind(rawValue: kindRaw),
              let eventId = database.columnText(statement, 1),
              let source = database.columnText(statement, 6),
              let agentKey = database.columnText(statement, 7) else {
            return nil
        }
        var draft = AgentJournalEventDraft(
            eventId: eventId,
            kind: kind,
            occurredAtMs: database.columnInt64(statement, 4),
            source: source,
            agentKey: agentKey,
            sessionId: database.columnText(statement, 8),
            workspaceId: database.columnText(statement, 9),
            surfaceId: database.columnText(statement, 10),
            unattributedReason: database.columnText(statement, 11),
            isSubagent: database.columnInt64(statement, 12) != 0,
            pendingWork: database.columnInt64(statement, 13) != 0,
            nativeEvent: database.columnText(statement, 14),
            declaredPhase: database.columnText(statement, 15)
                .flatMap(AgentLifecyclePhase.init(rawValue:)),
            detail: database.columnText(statement, 16)
        )
        draft.schemaVersion = Int(database.columnInt64(statement, 2))
        return AgentJournalEvent(
            sequence: database.columnInt64(statement, 0),
            committedAtMs: database.columnInt64(statement, 5),
            draft: draft
        )
    }

    private static func scalarInt64(
        _ database: AgentJournalDatabase,
        _ sql: String,
        binding parameters: [AgentJournalDatabase.BindValue]
    ) throws -> Int64? {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: parameters)
        guard database.step(statement) == SQLITE_ROW else { return nil }
        return database.columnInt64(statement, 0)
    }

    private static func migrate(_ database: AgentJournalDatabase) throws {
        try database.exec(
            """
            CREATE TABLE IF NOT EXISTS agent_journal (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT UNIQUE NOT NULL,
                schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                kind TEXT NOT NULL,
                occurred_at_ms INTEGER NOT NULL CHECK(occurred_at_ms >= 0),
                committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
                source TEXT NOT NULL,
                agent_key TEXT NOT NULL,
                session_id TEXT,
                workspace_id TEXT,
                surface_id TEXT,
                unattributed_reason TEXT,
                is_subagent INTEGER NOT NULL CHECK(is_subagent IN (0, 1)),
                pending_work INTEGER NOT NULL CHECK(pending_work IN (0, 1)),
                native_event TEXT,
                declared_phase TEXT,
                detail TEXT
            );
            CREATE INDEX IF NOT EXISTS agent_journal_by_surface_sequence
                ON agent_journal(surface_id, sequence);
            CREATE TABLE IF NOT EXISTS surface_alias (
                old_surface_id TEXT PRIMARY KEY NOT NULL,
                new_surface_id TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS workspace_alias (
                old_workspace_id TEXT PRIMARY KEY NOT NULL,
                new_workspace_id TEXT NOT NULL
            );
            PRAGMA user_version = 1;
            """
        )
        try installImmutabilityTriggers(database)
    }

    private static func installImmutabilityTriggers(_ database: AgentJournalDatabase) throws {
        try database.exec(
            """
            CREATE TRIGGER IF NOT EXISTS agent_journal_reject_update
                BEFORE UPDATE ON agent_journal
            BEGIN
                SELECT RAISE(ABORT, 'agent journal is append-only');
            END;
            CREATE TRIGGER IF NOT EXISTS agent_journal_reject_delete
                BEFORE DELETE ON agent_journal
            BEGIN
                SELECT RAISE(ABORT, 'agent journal is append-only');
            END;
            """
        )
    }

    /// Retention: the append-only contract protects live history from
    /// tampering, not from bounded aging-out. When the table exceeds the open
    /// cap, drop the guard triggers inside one transaction, delete the oldest
    /// rows down to the retained count, and reinstall the triggers.
    /// AUTOINCREMENT guarantees pruned sequences are never reused.
    private static func pruneIfNeeded(_ database: AgentJournalDatabase) throws {
        let count = try scalarInt64(
            database,
            "SELECT COUNT(*) FROM agent_journal;",
            binding: []
        ) ?? 0
        guard count > Int64(maximumEventCountAtOpen) else { return }
        try database.transaction {
            try database.exec(
                """
                DROP TRIGGER IF EXISTS agent_journal_reject_update;
                DROP TRIGGER IF EXISTS agent_journal_reject_delete;
                """
            )
            try database.exec(
                """
                DELETE FROM agent_journal WHERE sequence <= (
                    SELECT COALESCE(MAX(sequence), 0) - ?1 FROM agent_journal
                );
                """,
                binding: [.int(Int64(retainedEventCountAfterPrune))]
            )
            try installImmutabilityTriggers(database)
        }
    }
}
