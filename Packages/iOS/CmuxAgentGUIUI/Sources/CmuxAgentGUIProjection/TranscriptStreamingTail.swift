public import CmuxAgentReplica

/// Platform-neutral streaming tail input for the transcript projector.
public struct TranscriptStreamingTail: Hashable, Sendable {
    /// The journal receiving the streaming preview.
    public let journalID: JournalID
    /// The committed tail sequence the preview follows.
    public let afterSeq: EntrySeq
    /// The bounded text preview.
    public let textTail: String
    /// The preview revision.
    public let revision: Int

    /// Creates a streaming-tail preview.
    /// - Parameters:
    ///   - journalID: The journal receiving the preview.
    ///   - afterSeq: The committed tail sequence the preview follows.
    ///   - textTail: The bounded text preview.
    ///   - revision: The preview revision.
    public init(journalID: JournalID, afterSeq: EntrySeq, textTail: String, revision: Int) {
        self.journalID = journalID
        self.afterSeq = afterSeq
        self.textTail = textTail
        self.revision = revision
    }
}
