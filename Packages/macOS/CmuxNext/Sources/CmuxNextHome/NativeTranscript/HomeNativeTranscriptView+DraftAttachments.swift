import CmuxHomeCore

/// The composer's draft attachments by content hash, for a source that takes back what it added
/// (design mode: a highlight removed on the page, or a card replaced after an edit).
extension HomeNativeTranscriptView {
    /// The content hashes of the draft's attachments, in the order they arrived.
    public var draftAttachmentHashes: [String] { transcript.draftAttachments.map(\.ref.hash) }

    /// Takes these attachments out of the draft; a hash the draft does not hold is ignored.
    public func removeDraftAttachments(_ hashes: [String]) {
        for hash in hashes { transcript.removeDraftAttachment(hash) }
    }
}
