public import CmuxAgentReplica

/// Event payload appending whole-value entries to one journal.
public struct GuiEntriesAppendedEvent: Codable, Hashable, Sendable {
    /// The journal receiving the entries.
    public let journalID: JournalID
    /// The appended whole-value entries.
    public let entries: [EntrySnapshot]

    private enum CodingKeys: String, CodingKey {
        case journalID = "journal_id"
        case entries
    }

    /// Creates an entries-appended payload.
    /// - Parameters:
    ///   - journalID: The journal receiving the entries.
    ///   - entries: The appended whole-value entries.
    public init(journalID: JournalID, entries: [EntrySnapshot]) {
        self.journalID = journalID
        self.entries = entries
    }
}
