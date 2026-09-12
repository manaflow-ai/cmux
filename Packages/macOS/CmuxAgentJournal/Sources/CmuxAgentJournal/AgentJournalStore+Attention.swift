internal import Foundation
internal import SQLite3

extension AgentJournalStore {
    /// Reserves a semantic event before any notification effect is dispatched.
    ///
    /// Receipts outlive notification read/dismissal and journal compaction. A crash
    /// after this commit may lose effects, but can never replay them after restart.
    /// - Parameter identity: The reconciler's stable semantic identity.
    /// - Returns: `true` only for the first reservation, including across processes.
    /// - Throws: A storage error; callers must fail closed and report it.
    public func claimNotification(identity: String) throws -> Bool {
        try withDatabase { database in
            try database.exec("INSERT OR IGNORE INTO agent_notification_receipt(identity) VALUES (?1);",
                              binding: [.text(identity)])
            return try Self.scalarInt64(database, "SELECT changes();", binding: []) == 1
        }
    }

    static func migrateAttention(_ database: AgentJournalDatabase) throws {
        try database.exec("""
            CREATE TABLE IF NOT EXISTS agent_attention_context (
                event_id TEXT PRIMARY KEY NOT NULL, context TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_notification_receipt (
                identity TEXT PRIMARY KEY NOT NULL
            );
            """)
    }

    static func writeAttention(_ database: AgentJournalDatabase, eventId: String,
                               attention: AgentAttentionContext?) throws {
        guard let attention else { return }
        let data = try JSONEncoder().encode(attention)
        try database.exec("INSERT INTO agent_attention_context(event_id, context) VALUES (?1, ?2);",
                          binding: [.text(eventId), .text(String(decoding: data, as: UTF8.self))])
    }

    static func readAttention(_ database: AgentJournalDatabase, eventId: String) throws -> AgentAttentionContext? {
        let statement = try database.prepare("SELECT context FROM agent_attention_context WHERE event_id = ?1;")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(eventId)])
        guard database.step(statement) == SQLITE_ROW,
              let json = database.columnText(statement, 0) else { return nil }
        return try JSONDecoder().decode(AgentAttentionContext.self, from: Data(json.utf8))
    }
}
