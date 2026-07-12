public import CmuxAgentReplica

/// Event payload replacing one previously identified entry.
public struct GuiEntryReplacedEvent: Codable, Hashable, Sendable {
    /// The journal that owns the replacement.
    public let journalID: JournalID
    /// The replacement whole-value entry.
    public let entry: EntrySnapshot

    private enum CodingKeys: String, CodingKey {
        case journalID = "journal_id"
        case entry
    }

    /// Creates an entry-replacement payload.
    /// - Parameters:
    ///   - journalID: The journal that owns the entry.
    ///   - entry: The replacement whole-value entry.
    public init(journalID: JournalID, entry: EntrySnapshot) {
        self.journalID = journalID
        self.entry = entry
    }
}
