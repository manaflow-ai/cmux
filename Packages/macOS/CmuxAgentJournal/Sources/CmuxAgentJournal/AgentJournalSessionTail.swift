public import Foundation
internal import SQLite3

/// The journal's view of one agent session: when it was last active and
/// whether its most recent start was followed by an end.
public struct AgentJournalSessionTail: Equatable, Sendable {
    public var sessionId: String
    public var source: String
    public var lastOccurredAtMs: Int64
    public var hasEnded: Bool

    public init(sessionId: String, source: String, lastOccurredAtMs: Int64, hasEnded: Bool) {
        self.sessionId = sessionId
        self.source = source
        self.lastOccurredAtMs = lastOccurredAtMs
        self.hasEnded = hasEnded
    }
}

extension AgentJournalStore {
    /// One tail per top-level agent session with an event at or after
    /// `occurredAtOrAfterMs`. Used after an unclean exit to find the sessions
    /// that were still running when the app died.
    ///
    /// - Parameter occurredAtOrAfterMs: Lower bound on event time, in ms.
    /// - Returns: Session tails in no particular order.
    /// - Throws: A storage error.
    public func sessionTails(occurredAtOrAfterMs: Int64) throws -> [AgentJournalSessionTail] {
        try withDatabase { database in
            let statement = try database.prepare(
                """
                SELECT session_id, MAX(source), MAX(occurred_at_ms),
                       MAX(CASE WHEN kind = 'agent.session.ended' THEN sequence END),
                       MAX(CASE WHEN kind = 'agent.session.started' THEN sequence END)
                FROM agent_journal
                WHERE session_id IS NOT NULL AND COALESCE(is_subagent, 0) = 0 AND occurred_at_ms >= ?1
                GROUP BY session_id;
                """
            )
            defer { sqlite3_finalize(statement) }
            try database.bind(statement: statement, parameters: [.int(occurredAtOrAfterMs)])
            var tails: [AgentJournalSessionTail] = []
            while database.step(statement) == SQLITE_ROW {
                guard let sessionId = database.columnText(statement, 0), !sessionId.isEmpty else { continue }
                let endedSequence = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : database.columnInt64(statement, 3)
                let startedSequence = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? Int64(0) : database.columnInt64(statement, 4)
                tails.append(AgentJournalSessionTail(
                    sessionId: sessionId,
                    source: database.columnText(statement, 1) ?? "",
                    lastOccurredAtMs: database.columnInt64(statement, 2),
                    hasEnded: endedSequence.map { $0 >= startedSequence } ?? false
                ))
            }
            return tails
        }
    }
}
