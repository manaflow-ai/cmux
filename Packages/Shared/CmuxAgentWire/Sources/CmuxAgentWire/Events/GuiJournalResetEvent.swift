public import CmuxAgentReplica

/// Event payload rotating a session to a newly identified journal.
public struct GuiJournalResetEvent: Codable, Hashable, Sendable {
    /// The session whose journal rotated.
    public let sessionID: AgentSessionID
    /// The new journal identifier.
    public let newJournalID: JournalID
    /// The advertised tail sequence in the new journal.
    public let tailSeq: EntrySeq

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case newJournalID = "new_journal_id"
        case tailSeq = "tail_seq"
    }

    /// Creates a journal-reset payload.
    /// - Parameters:
    ///   - sessionID: The session whose journal rotated.
    ///   - newJournalID: The new journal identifier.
    ///   - tailSeq: The advertised tail sequence.
    public init(sessionID: AgentSessionID, newJournalID: JournalID, tailSeq: EntrySeq) {
        self.sessionID = sessionID
        self.newJournalID = newJournalID
        self.tailSeq = tailSeq
    }
}
