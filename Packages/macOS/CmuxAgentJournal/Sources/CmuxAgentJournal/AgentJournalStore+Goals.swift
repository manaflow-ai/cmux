internal import Foundation
internal import SQLite3

extension AgentJournalStore {
    /// Reads the durable objective projection for one provider session.
    ///
    /// - Parameters:
    ///   - source: Canonical provider identifier.
    ///   - sessionId: Exact provider session identifier, independent of surface moves.
    /// - Returns: The last accepted objective state, or `nil` for unmanaged sessions.
    /// - Throws: A storage error. Consumers must report unknown on failure.
    public func goalLifecycle(source: String, sessionId: String) throws -> AgentGoalLifecycle? {
        try withDatabase { try Self.readCurrentGoal($0, source: source, sessionId: sessionId) }
    }

    /// Reads several durable objective projections in one indexed query.
    ///
    /// - Parameter requests: Provider and exact session identities. The
    ///   returned array preserves this order; a `nil` element means that the
    ///   session has no committed objective projection.
    /// - Returns: One projection or `nil` for each requested identity.
    /// - Throws: A storage error when the projection cannot be read.
    public func goalLifecycles(
        _ requests: [(source: String, sessionId: String)]
    ) throws -> [AgentGoalLifecycle?] {
        guard !requests.isEmpty else { return [] }
        return try withDatabase {
            try Self.readCurrentGoals($0, requests: requests)
        }
    }

    static func migrateGoals(_ database: AgentJournalDatabase) throws {
        try database.exec("""
            CREATE TABLE IF NOT EXISTS agent_goal_context (
                event_id TEXT PRIMARY KEY NOT NULL, goal_lifecycle TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_goal_current (
                source TEXT NOT NULL, session_id TEXT NOT NULL, goal_lifecycle TEXT NOT NULL,
                PRIMARY KEY(source, session_id)
            );
            CREATE TABLE IF NOT EXISTS agent_goal_generation (
                source TEXT NOT NULL, session_id TEXT NOT NULL, generation TEXT NOT NULL,
                PRIMARY KEY(source, session_id, generation)
            );
            """)
    }

    /// Runs inside the event append transaction. Projection and event either both
    /// commit or neither does. Projection and generation fences outlive retention.
    static func writeGoalLifecycle(_ database: AgentJournalDatabase, draft: AgentJournalEventDraft) throws {
        guard let goal = draft.goalLifecycle, let sessionId = draft.sessionId else { return }
        let current = try readCurrentGoal(database, source: draft.source, sessionId: sessionId)
        if let current {
            if current.generation == goal.generation {
                guard goal.updatedAtMs > current.updatedAtMs,
                      !current.state.isTerminal || goal.state == .complete else {
                    throw AgentJournalStoreError.invalidDraft("stale or terminal goal generation")
                }
            } else {
                guard goal.previousGeneration == current.generation,
                      goal.updatedAtMs > current.updatedAtMs else {
                    throw AgentJournalStoreError.invalidDraft("goal generation replacement requires the current generation")
                }
                let seen = try scalarInt64(database,
                    "SELECT COUNT(*) FROM agent_goal_generation WHERE source = ?1 AND session_id = ?2 AND generation = ?3;",
                    binding: [.text(draft.source), .text(sessionId), .text(goal.generation)])
                guard seen == 0 else {
                    throw AgentJournalStoreError.invalidDraft("retired goal generation")
                }
            }
        } else if goal.previousGeneration != nil {
            throw AgentJournalStoreError.invalidDraft("goal generation does not exist")
        }
        let json = String(decoding: try JSONEncoder().encode(goal), as: UTF8.self)
        try database.exec("INSERT INTO agent_goal_context(event_id, goal_lifecycle) VALUES (?1, ?2);",
                          binding: [.text(draft.eventId), .text(json)])
        try database.exec("""
            INSERT INTO agent_goal_current(source, session_id, goal_lifecycle) VALUES (?1, ?2, ?3)
            ON CONFLICT(source, session_id) DO UPDATE SET goal_lifecycle = excluded.goal_lifecycle;
            """, binding: [.text(draft.source), .text(sessionId), .text(json)])
        try database.exec("INSERT OR IGNORE INTO agent_goal_generation(source, session_id, generation) VALUES (?1, ?2, ?3);",
                          binding: [.text(draft.source), .text(sessionId), .text(goal.generation)])
    }

    static func readGoalLifecycle(_ database: AgentJournalDatabase, eventId: String) throws -> AgentGoalLifecycle? {
        let statement = try database.prepare("SELECT goal_lifecycle FROM agent_goal_context WHERE event_id = ?1;")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(eventId)])
        guard database.step(statement) == SQLITE_ROW,
              let json = database.columnText(statement, 0) else { return nil }
        return try JSONDecoder().decode(AgentGoalLifecycle.self, from: Data(json.utf8))
    }

    private static func readCurrentGoal(_ database: AgentJournalDatabase, source: String,
                                        sessionId: String) throws -> AgentGoalLifecycle? {
        let statement = try database.prepare("SELECT goal_lifecycle FROM agent_goal_current WHERE source = ?1 AND session_id = ?2;")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement: statement, parameters: [.text(source), .text(sessionId)])
        let result = database.step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let json = database.columnText(statement, 0) else {
            throw AgentJournalStoreError.stepFailed(result, "goal projection unavailable")
        }
        return try JSONDecoder().decode(AgentGoalLifecycle.self, from: Data(json.utf8))
    }

    private static func readCurrentGoals(
        _ database: AgentJournalDatabase,
        requests: [(source: String, sessionId: String)]
    ) throws -> [AgentGoalLifecycle?] {
        let statement = try database.prepare("""
            WITH requested(source, session_id, ordinal) AS (
                VALUES \(requests.enumerated().map { index, _ in
                    "(?\(index * 2 + 1), ?\(index * 2 + 2), \(index))"
                }.joined(separator: ", "))
            )
            SELECT requested.ordinal, agent_goal_current.goal_lifecycle
            FROM requested
            LEFT JOIN agent_goal_current
              ON agent_goal_current.source = requested.source
             AND agent_goal_current.session_id = requested.session_id
            ORDER BY requested.ordinal;
            """)
        defer { sqlite3_finalize(statement) }
        let parameters = requests.flatMap { [AgentJournalDatabase.BindValue.text($0.source), .text($0.sessionId)] }
        try database.bind(statement: statement, parameters: parameters)
        var results: [AgentGoalLifecycle?] = []
        let decoder = JSONDecoder()
        while true {
            let result = database.step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw AgentJournalStoreError.stepFailed(result, "goal projection unavailable")
            }
            guard database.columnInt64(statement, 0) == Int64(results.count) else {
                throw AgentJournalStoreError.stepFailed(SQLITE_ERROR, "goal projection order changed")
            }
            guard let json = database.columnText(statement, 1) else {
                results.append(nil)
                continue
            }
            results.append(try decoder.decode(AgentGoalLifecycle.self, from: Data(json.utf8)))
        }
        guard results.count == requests.count else {
            throw AgentJournalStoreError.stepFailed(SQLITE_ERROR, "goal projection result incomplete")
        }
        return results
    }
}
