public import Foundation
public import CmuxAgentReplica

/// Stable identity for one projected transcript row.
public enum TranscriptRowID: Hashable, Sendable, CustomStringConvertible {
    /// A row derived from a journal entry.
    case entry(journalID: JournalID, seq: EntrySeq)
    /// A synthetic date header for a display day.
    case dateHeader(String)
    /// The oldest-history boundary marker.
    case boundary
    /// A known gap in the local entry window.
    case hole(EntryRange)
    /// A pending local send ticket.
    case pendingTicket(UUID)
    /// A pending ask projected as compact activity.
    case pendingAsk(String)
    /// The single ephemeral streaming preview row.
    case streaming(journalID: JournalID, afterSeq: EntrySeq)
    /// The folded activity for a completed turn.
    case activitySummary(TranscriptTurnID)
    /// A later folded activity run separated by visible prose or attachments.
    case activitySegment(turnID: TranscriptTurnID, anchorSeq: EntrySeq)

    /// A deterministic string form suitable for diff diagnostics and UI reuse identifiers.
    public var description: String {
        switch self {
        case .entry(let journalID, let seq):
            "entry:\(journalID.rawValue):\(seq.rawValue)"
        case .dateHeader(let dayKey):
            "date:\(dayKey)"
        case .boundary:
            "boundary"
        case .hole(let range):
            "hole:\(range.lowerBound.rawValue)-\(range.upperBound.rawValue)"
        case .pendingTicket(let id):
            "ticket:\(id.uuidString)"
        case .pendingAsk(let id):
            "ask:\(id)"
        case .streaming(let journalID, let afterSeq):
            "streaming:\(journalID.rawValue):\(afterSeq.rawValue)"
        case .activitySummary(let turnID):
            "activity:\(turnID.description)"
        case .activitySegment(let turnID, let anchorSeq):
            "activity:\(turnID.description):\(anchorSeq.rawValue)"
        }
    }
}
