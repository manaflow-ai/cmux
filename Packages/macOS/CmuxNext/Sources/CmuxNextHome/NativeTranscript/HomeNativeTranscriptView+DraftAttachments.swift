import CmuxHomeCore

/// The composer's draft attachments by chip id, for a source that takes back what it added
/// (design mode: a highlight removed on the page, or a card replaced after an edit). A chip's id is
/// its content hash, or `hash#N` for another copy of the same file: each one added is its own chip.
extension HomeNativeTranscriptView {
    /// The chip ids of the draft's attachments, in the order they arrived.
    public var draftAttachmentIDs: [String] { transcript.draftAttachmentIDs }

    /// The draft's chip ids, in order, each time they change: a chip added or removed, or the draft
    /// sent. One listener: the last one set.
    public var onDraftAttachmentsChange: ([String]) -> Void {
        get { transcript.onDraftAttachmentsChange }
        set { transcript.onDraftAttachmentsChange = newValue }
    }

    /// Takes these chips out of the draft; an id the draft does not hold is ignored.
    public func removeDraftAttachments(_ ids: [String]) {
        for id in ids { transcript.removeDraftAttachment(id) }
    }

    /// Adds the files at `paths` to the draft through the composer's own intake (as a drop), once
    /// earlier intake is done; the files may go once this returns, since the draft holds its copies.
    /// - Returns: The chip ids the files added, for ``removeDraftAttachments(_:)`` later;
    ///   nil when the composer refused them.
    public func addDraftFiles(_ paths: [String]) async -> [String]? {
        await attachmentsReady()
        let before = Set(draftAttachmentIDs)
        guard attachFiles(paths: paths, via: .drop) == .accepted else { return nil }
        await attachmentsReady()
        return draftAttachmentIDs.filter { !before.contains($0) }
    }
}
