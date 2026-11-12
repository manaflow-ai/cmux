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
    /// `occurredAtOrAfterMs`. Start and end are read from the session's whole
    /// history, so a stray late event cannot revive an ended session. Used
    /// after an unclean exit to find the sessions that were still running
    /// when the app died.
    ///
    /// - Parameter occurredAtOrAfterMs: Lower bound on event time, in ms.
    /// - Returns: Session tails in no particular order.
    /// - Throws: A storage error.
    public func sessionTails(occurredAtOrAfterMs: Int64) throws -> [AgentJournalSessionTail] {
        try withDatabase { try AgentJournalSessionTailReader.query($0, occurredAtOrAfterMs: occurredAtOrAfterMs) }
    }
}

/// Reads session tails from a journal file without opening it as the owner:
/// read-only, with no migration or pruning.
public struct AgentJournalSessionTailReader: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// See ``AgentJournalStore/sessionTails(occurredAtOrAfterMs:)``.
    public func sessionTails(occurredAtOrAfterMs: Int64) throws -> [AgentJournalSessionTail] {
        let database = try AgentJournalDatabase(readOnlyPath: databaseURL.path)
        defer { database.close() }
        return try Self.query(database, occurredAtOrAfterMs: occurredAtOrAfterMs)
    }

    static func query(_ database: AgentJournalDatabase, occurredAtOrAfterMs: Int64) throws -> [AgentJournalSessionTail] {
        let statement = try database.prepare(
            """
            SELECT j.session_id,
                   COALESCE(
                       (SELECT s.source FROM agent_journal s
                        WHERE s.session_id = j.session_id
                          AND s.kind = 'agent.session.started'
                          AND COALESCE(s.is_subagent, 0) = 0
                        ORDER BY s.sequence DESC LIMIT 1),
                       MAX(j.source)
                   ),
                   MAX(j.occurred_at_ms),
                   MAX(CASE WHEN j.kind = 'agent.session.ended' THEN j.sequence END),
                   MAX(CASE WHEN j.kind = 'agent.session.started' THEN j.sequence END)
            FROM agent_journal j
            WHERE j.session_id IS NOT NULL AND COALESCE(j.is_subagent, 0) = 0
            GROUP BY j.session_id
            HAVING MAX(j.occurred_at_ms) >= ?1;
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
