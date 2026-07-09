import Foundation

/// Captures the observable value state of a conversation replica for replay comparisons.
public struct ConversationReplicaState: Codable, Hashable, Sendable {
    /// The current journal, if known.
    public let journalID: JournalID?
    /// The advertised tail sequence.
    public let tailSeq: EntrySeq
    /// Loaded entries in ascending sequence order.
    public let entries: [EntrySnapshot]
    /// Loaded contiguous ranges.
    public let loadedRanges: [EntryRange]
    /// Explicit holes in the loaded window.
    public let holes: [EntryRange]
    /// Whether the sync layer should pull the tail.
    public let needsTailPull: Bool
    /// The read pointer sequence.
    public let readPointer: EntrySeq
    /// The derived unread count when exact.
    public let unreadCount: Int
    /// Whether ``unreadCount`` is exact.
    public let unreadIsExact: Bool
    /// FIFO send tickets.
    public let sendTickets: [SendTicket]
    /// Pending asks in stable order.
    public let asks: [PendingAsk]
    /// Count of journal reset marker boundaries.
    public let resetMarkerCount: Int
    /// Count of illegal ticket transitions.
    public let illegalTicketTransitionCount: Int

    /// Creates a conversation state snapshot.
    /// - Parameters:
    ///   - journalID: The current journal.
    ///   - tailSeq: The advertised tail sequence.
    ///   - entries: Loaded entries.
    ///   - loadedRanges: Loaded contiguous ranges.
    ///   - holes: Explicit holes.
    ///   - needsTailPull: Whether tail pull is needed.
    ///   - readPointer: The read pointer.
    ///   - unreadCount: The unread count.
    ///   - unreadIsExact: Whether the unread count is exact.
    ///   - sendTickets: FIFO send tickets.
    ///   - asks: Pending asks.
    ///   - resetMarkerCount: Journal reset marker count.
    ///   - illegalTicketTransitionCount: Illegal ticket transition count.
    public init(
        journalID: JournalID?,
        tailSeq: EntrySeq,
        entries: [EntrySnapshot],
        loadedRanges: [EntryRange],
        holes: [EntryRange],
        needsTailPull: Bool,
        readPointer: EntrySeq,
        unreadCount: Int,
        unreadIsExact: Bool,
        sendTickets: [SendTicket],
        asks: [PendingAsk],
        resetMarkerCount: Int,
        illegalTicketTransitionCount: Int
    ) {
        self.journalID = journalID
        self.tailSeq = tailSeq
        self.entries = entries
        self.loadedRanges = loadedRanges
        self.holes = holes
        self.needsTailPull = needsTailPull
        self.readPointer = readPointer
        self.unreadCount = unreadCount
        self.unreadIsExact = unreadIsExact
        self.sendTickets = sendTickets
        self.asks = asks
        self.resetMarkerCount = resetMarkerCount
        self.illegalTicketTransitionCount = illegalTicketTransitionCount
    }
}
