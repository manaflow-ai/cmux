public import CmuxAgentReplica

/// Parameters for requesting a bounded journal page.
public struct GuiEntriesParams: Codable, Hashable, Sendable {
    /// The session whose journal is requested.
    public let sessionID: AgentSessionID
    /// The expected journal, or `nil` to accept the current journal.
    public let journalID: JournalID?
    /// The exclusive upper sequence bound for backward paging.
    public let beforeSeq: EntrySeq?
    /// The exclusive lower sequence bound for forward paging.
    public let afterSeq: EntrySeq?
    /// The client-requested page size; the server may clamp it.
    public let limit: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case journalID = "journal_id"
        case beforeSeq = "before_seq"
        case afterSeq = "after_seq"
        case limit
    }

    /// Creates journal-page parameters.
    /// - Parameters:
    ///   - sessionID: The session whose entries are requested.
    ///   - journalID: The expected journal, if known.
    ///   - beforeSeq: The exclusive upper bound for backward paging.
    ///   - afterSeq: The exclusive lower bound for forward paging.
    ///   - limit: The requested page size before server clamping.
    public init(
        sessionID: AgentSessionID,
        journalID: JournalID? = nil,
        beforeSeq: EntrySeq? = nil,
        afterSeq: EntrySeq? = nil,
        limit: Int
    ) {
        self.sessionID = sessionID
        self.journalID = journalID
        self.beforeSeq = beforeSeq
        self.afterSeq = afterSeq
        self.limit = limit
    }
}

/// Result containing a bounded journal window and its advertised boundaries.
public struct GuiEntriesResult: Codable, Hashable, Sendable {
    /// The journal that owns every returned entry.
    public let journalID: JournalID
    /// Valid whole-value entries decoded from the page.
    public let entries: [EntrySnapshot]
    /// The first sequence represented by the returned window.
    public let windowStart: EntrySeq
    /// The last sequence represented by the returned window.
    public let windowEnd: EntrySeq
    /// The server's current journal tail sequence.
    public let tailSeq: EntrySeq
    /// Whether an earlier page may be requested.
    public let hasMoreBefore: Bool
    /// The number of malformed entry elements discarded while decoding.
    public let malformedEntryCount: Int

    private enum CodingKeys: String, CodingKey {
        case journalID = "journal_id"
        case entries
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case tailSeq = "tail_seq"
        case hasMoreBefore = "has_more_before"
    }

    /// Creates a journal-page result with no decode diagnostics.
    /// - Parameters:
    ///   - journalID: The journal that owns the entries.
    ///   - entries: Whole-value entries in the page.
    ///   - windowStart: The first represented sequence.
    ///   - windowEnd: The last represented sequence.
    ///   - tailSeq: The server's current tail sequence.
    ///   - hasMoreBefore: Whether an earlier page may be requested.
    public init(
        journalID: JournalID,
        entries: [EntrySnapshot],
        windowStart: EntrySeq,
        windowEnd: EntrySeq,
        tailSeq: EntrySeq,
        hasMoreBefore: Bool
    ) {
        self.journalID = journalID
        self.entries = entries
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.tailSeq = tailSeq
        self.hasMoreBefore = hasMoreBefore
        self.malformedEntryCount = 0
    }

    /// Decodes a journal page while discarding only malformed entry elements.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = (try? container.decode([LossyEntry].self, forKey: .entries)) ?? []
        self.journalID = try container.decode(JournalID.self, forKey: .journalID)
        self.entries = decodedEntries.compactMap(\.value)
        self.windowStart = try container.decode(EntrySeq.self, forKey: .windowStart)
        self.windowEnd = try container.decode(EntrySeq.self, forKey: .windowEnd)
        self.tailSeq = try container.decode(EntrySeq.self, forKey: .tailSeq)
        self.hasMoreBefore = try container.decode(Bool.self, forKey: .hasMoreBefore)
        self.malformedEntryCount = decodedEntries.count - entries.count
    }

    /// Encodes the wire page without local decode diagnostics.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(journalID, forKey: .journalID)
        try container.encode(entries, forKey: .entries)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encode(windowEnd, forKey: .windowEnd)
        try container.encode(tailSeq, forKey: .tailSeq)
        try container.encode(hasMoreBefore, forKey: .hasMoreBefore)
    }
}

private struct LossyEntry: Decodable {
    let value: EntrySnapshot?

    init(from decoder: any Decoder) throws {
        self.value = try? EntrySnapshot(from: decoder)
    }
}
