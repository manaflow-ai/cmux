/// Immutable snapshot of a text box's draft content at one revision, used to decide
/// whether a failed submit should restore the previously cleared draft. Captures the
/// revision counter at clear time plus enough content shape (text emptiness, attachment
/// count) to detect whether the user has since typed something new.
public struct TextBoxFailedSubmitRollbackSnapshot: Equatable {
    /// The text box's content revision at the moment the snapshot was taken.
    public let revision: UInt64
    /// The draft text captured in the snapshot.
    public let text: String
    /// The number of attachments captured in the snapshot.
    public let attachmentCount: Int

    /// Creates a snapshot of draft content at a given revision.
    public init(revision: UInt64, text: String, attachmentCount: Int) {
        self.revision = revision
        self.text = text
        self.attachmentCount = attachmentCount
    }

    /// `true` when the snapshot holds neither text nor attachments.
    public var isEmpty: Bool {
        text.isEmpty && attachmentCount == 0
    }

    /// Decides whether a failed submit should restore this (cleared-at-submit) snapshot.
    ///
    /// Restoration is safe only when the live content is still at the same revision this
    /// snapshot was taken at and is currently empty, meaning the user has not typed anything
    /// new since the clear. The receiver is the snapshot recorded when the box was cleared
    /// for submission; `current` is the live content sampled at completion time.
    public func shouldRestore(current: TextBoxFailedSubmitRollbackSnapshot) -> Bool {
        current.revision == revision && current.isEmpty
    }
}
