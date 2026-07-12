public import CmuxAgentReplica

/// Stable identity for one projected segment of a prompt-led conversation turn or prelude.
public struct TranscriptTurnID: Hashable, Sendable, CustomStringConvertible {
    /// Journal containing the turn.
    public let journalID: JournalID
    /// User prompt sequence, or `nil` for prelude content.
    public let promptSeq: EntrySeq?
    /// First retained entry sequence in this projected segment.
    public let segmentAnchorSeq: EntrySeq?

    /// Creates a stable turn identity.
    /// - Parameters:
    ///   - journalID: Journal containing the turn.
    ///   - promptSeq: Prompt sequence, or `nil` for prelude content.
    ///   - segmentAnchorSeq: First retained entry sequence in the segment, when known.
    public init(journalID: JournalID, promptSeq: EntrySeq?, segmentAnchorSeq: EntrySeq? = nil) {
        self.journalID = journalID
        self.promptSeq = promptSeq
        self.segmentAnchorSeq = segmentAnchorSeq
    }

    /// Deterministic diagnostic form.
    public var description: String {
        let prompt = promptSeq?.rawValue.description ?? "prelude"
        let segment = segmentAnchorSeq?.rawValue.description ?? "unanchored"
        return "turn:\(journalID.rawValue):\(prompt):segment:\(segment)"
    }
}
