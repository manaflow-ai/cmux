public import Foundation

/// Folds one machine's session journal agent records into agent sessions
/// (plans/cmux-next/history.md 2, `agent`). Constant work per record;
/// records arrive in journal order, and a record at or below `cursor` is
/// ignored, so re-reading from an older cursor never double counts.
public nonisolated struct AgentSessionFold: Hashable, Sendable, Codable {
    public let machine: String
    /// The last applied journal sequence.
    public private(set) var cursor: UInt64 = 0
    /// Keyed `<provider>/<session id>`.
    public private(set) var sessions: [String: AgentSession] = [:]
    /// Most sessions kept; the least recently active go first.
    public let capacity: Int

    public init(machine: String, capacity: Int = 500) {
        self.machine = machine
        self.capacity = max(1, capacity)
    }

    /// Kinds the app asks the journal for.
    public static let journalKinds = ["agent.session.*", "agent.turn.*", "agent.state.changed"]

    public mutating func apply(_ records: [AgentJournalRecord]) {
        for record in records where record.sequence > cursor {
            apply(record)
            cursor = record.sequence
        }
        trim()
    }

    /// Newest activity first.
    public var ordered: [AgentSession] {
        sessions.values.sorted { ($0.lastActivityAt, $0.sessionID) > ($1.lastActivityAt, $1.sessionID) }
    }

    private mutating func apply(_ record: AgentJournalRecord) {
        guard record.kind.hasPrefix("agent."),
              let normalized = record.payload?.normalized,
              let sessionID = normalized.agentSessionID ?? normalized.rootAgentSessionID, !sessionID.isEmpty else { return }
        let provider = record.payload?.adapter?.id ?? "agent"
        let time = Self.time(of: record)
        let key = "\(provider)/\(sessionID)"
        var session = sessions[key] ?? AgentSession(machine: machine, provider: provider, sessionID: sessionID,
                                                    startedAt: time, lastActivityAt: time)
        switch record.kind {
        case "agent.session.started":
            // A resumed session reuses its id: it runs again.
            if session.endedAt != nil { session.endedAt = nil }
            session.startedAt = min(session.startedAt, time)
        case "agent.session.ended":
            session.endedAt = time
        default:
            if let ended = session.endedAt, time > ended { session.endedAt = nil }
        }
        session.lastActivityAt = max(session.lastActivityAt, time)
        if let cwd = normalized.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let terminal = record.subject("terminal") { session.terminal = terminal }
        if let tab = record.subject("tab") { session.tab = tab }
        if let workspace = record.subject("workspace") { session.workspace = workspace }
        sessions[key] = session
    }

    private mutating func trim() {
        guard sessions.count > capacity else { return }
        for session in ordered.dropFirst(capacity) {
            sessions["\(session.provider)/\(session.sessionID)"] = nil
        }
    }

    /// The hook's own observation time, else the journal's occurrence time.
    static func time(of record: AgentJournalRecord) -> Date {
        if let text = record.payload?.normalized?.observedAtMs, let ms = Int64(text) {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return Date(timeIntervalSince1970: TimeInterval(record.occurredAtMs ?? 0) / 1000)
    }
}
