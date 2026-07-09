public import CmuxAgentReplica
import Foundation

/// Identifies one decoded payload side-table entry.
public struct EntryCoordinate: Hashable, Sendable {
    /// The journal id.
    public let journalID: JournalID
    /// The journal-local sequence.
    public let seq: EntrySeq

    /// Creates an entry coordinate.
    /// - Parameters:
    ///   - journalID: The journal id.
    ///   - seq: The journal-local sequence.
    public init(journalID: JournalID, seq: EntrySeq) {
        self.journalID = journalID
        self.seq = seq
    }
}
