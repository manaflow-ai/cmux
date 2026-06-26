/// A point-in-time capture of a text box's draft state, used to decide whether a
/// failed submit should restore the previously cleared draft.
///
/// The snapshot records the content `revision` at the moment of submit plus the
/// text and attachment count, so a later restore can confirm the field is still
/// the same untouched, cleared draft before putting the content back.
public struct TextBoxFailedSubmitRollbackSnapshot: Equatable {
    /// Monotonic content revision of the text box when this snapshot was taken.
    public let revision: UInt64
    /// Plain text contents of the text box at snapshot time.
    public let text: String
    /// Number of attachments present at snapshot time.
    public let attachmentCount: Int

    /// Creates a snapshot of the text box's draft state.
    public init(revision: UInt64, text: String, attachmentCount: Int) {
        self.revision = revision
        self.text = text
        self.attachmentCount = attachmentCount
    }

    /// `true` when the text box has neither text nor attachments.
    public var isEmpty: Bool {
        text.isEmpty && attachmentCount == 0
    }

    /// Decides whether this recorded rollback snapshot should restore its draft,
    /// given the text box's `current` snapshot.
    ///
    /// Restore only when the content revision is unchanged since submit and the
    /// field is still empty, i.e. the user has not typed a new draft into the
    /// just-cleared field while the submit was in flight.
    public func shouldRestore(givenCurrent current: TextBoxFailedSubmitRollbackSnapshot) -> Bool {
        current.revision == revision && current.isEmpty
    }
}
