/// One page of a sequence-ordered journal read.
///
/// `scannedThroughSequence` is the pagination cursor: it advances over every
/// row the page scanned, including rows that failed to decode (foreign kinds
/// written by a newer schema), so a reader can never stall on an undecodable
/// run and never silently loses track of skipped history —
/// ``skippedSequences`` names the rows the page could not decode.
public struct AgentJournalReadPage: Sendable, Equatable {
    /// The decoded events, in ascending sequence order.
    public let events: [AgentJournalEvent]
    /// The highest sequence the page scanned (0 when the page is empty);
    /// pass this as the next `afterSequence`.
    public let scannedThroughSequence: Int64
    /// Sequences of scanned rows that could not be decoded.
    public let skippedSequences: [Int64]

    /// Creates a page.
    ///
    /// - Parameters:
    ///   - events: The decoded events in ascending sequence order.
    ///   - scannedThroughSequence: The highest scanned sequence.
    ///   - skippedSequences: Sequences of rows that could not be decoded.
    public init(
        events: [AgentJournalEvent],
        scannedThroughSequence: Int64,
        skippedSequences: [Int64]
    ) {
        self.events = events
        self.scannedThroughSequence = scannedThroughSequence
        self.skippedSequences = skippedSequences
    }

    /// Whether the page scanned no rows (the read is exhausted).
    public var isEmpty: Bool { scannedThroughSequence == 0 }
}
