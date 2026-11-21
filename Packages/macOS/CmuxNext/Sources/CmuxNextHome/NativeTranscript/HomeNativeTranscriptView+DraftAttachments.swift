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

    /// Adds the files at `paths` to the draft through the composer's own intake (as a drop), once
    /// earlier intake is done; the files may go once this returns, since the draft holds its copies.
    /// - Returns: The content hashes the files added, for ``removeDraftAttachments(_:)`` later;
    ///   nil when the composer refused them.
    public func addDraftFiles(_ paths: [String]) async -> [String]? {
        await attachmentsReady()
        let before = Set(draftAttachmentHashes)
        guard attachFiles(paths: paths, via: .drop) == .accepted else { return nil }
        await attachmentsReady()
        return draftAttachmentHashes.filter { !before.contains($0) }
    }
}
