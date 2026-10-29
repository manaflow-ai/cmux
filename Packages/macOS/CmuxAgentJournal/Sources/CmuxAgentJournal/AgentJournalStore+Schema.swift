internal import SQLite3

extension AgentJournalStore {
    static func migrate(_ database: AgentJournalDatabase) throws {
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

    static func installImmutabilityTriggers(_ database: AgentJournalDatabase) throws {
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
    static func pruneIfNeeded(_ database: AgentJournalDatabase,
                              maximumCount: Int = maximumEventCountAtOpen,
                              retainedCount: Int = retainedEventCountAfterPrune) throws {
        let count = try scalarInt64(
            database,
            "SELECT COUNT(*) FROM agent_journal;",
            binding: []
        ) ?? 0
        guard count > Int64(maximumCount) else { return }
        // Cut by row rank, not by sequence arithmetic: prior prunes leave
        // sequence gaps, so MAX(sequence) - N would retain the wrong count.
        guard let cutoff = try scalarInt64(
            database,
            """
            SELECT sequence FROM agent_journal
            ORDER BY sequence DESC LIMIT 1 OFFSET ?1;
            """,
            binding: [.int(Int64(retainedCount - 1))]
        ) else { return }
        try database.transaction {
            try database.exec(
                """
                DROP TRIGGER IF EXISTS agent_journal_reject_update;
                DROP TRIGGER IF EXISTS agent_journal_reject_delete;
                """
            )
            try database.exec(
                "DELETE FROM agent_journal WHERE sequence < ?1;",
                binding: [.int(cutoff)]
            )
            try database.exec("DELETE FROM agent_attention_context WHERE event_id NOT IN (SELECT event_id FROM agent_journal);")
            try installImmutabilityTriggers(database)
        }
    }
}
