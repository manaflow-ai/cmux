public import CmuxAgentReplica

/// Stable identity for one prompt-led conversation turn or prelude.
public struct TranscriptTurnID: Hashable, Sendable, CustomStringConvertible {
    /// Journal containing the turn.
    public let journalID: JournalID
    /// User prompt sequence, or `nil` for prelude content.
    public let promptSeq: EntrySeq?

    /// Creates a stable turn identity.
    /// - Parameters:
    ///   - journalID: Journal containing the turn.
    ///   - promptSeq: Prompt sequence, or `nil` for prelude content.
    public init(journalID: JournalID, promptSeq: EntrySeq?) {
        self.journalID = journalID
        self.promptSeq = promptSeq
    }

    /// Deterministic diagnostic form.
    public var description: String {
        "turn:\(journalID.rawValue):\(promptSeq?.rawValue.description ?? "prelude")"
    }
}
