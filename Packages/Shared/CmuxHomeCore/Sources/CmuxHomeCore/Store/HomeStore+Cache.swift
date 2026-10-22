import Foundation

// HomeStore's client view state and durable cache. HomeClientViewCache owns
// drafts, scroll anchors and the coalesced writes; the store restores the
// mirror and the log from the snapshot and supplies the owner state to write.
extension HomeStore {
    /// The unsent text of a conversation's compose field.
    public func draft(for id: ConversationID) -> String? { viewCache.drafts[id] }

    /// Keeps the compose field's text; empty text clears it.
    public func setDraft(_ text: String, for id: ConversationID) {
        viewCache.setDraft(text, for: id)
    }

    /// The attachments left in a conversation's compose field, in order;
    /// one whose bytes left the blob cache is skipped.
    public func draftAttachments(for id: ConversationID) -> [LocalAttachment] {
        (viewCache.draftAttachments[id] ?? []).compactMap(\.local)
    }

    /// Keeps the compose field's attachments (their files stay in the blob
    /// cache); none clears them.
    public func setDraftAttachments(_ attachments: [LocalAttachment], for id: ConversationID) {
        viewCache.setDraftAttachments(attachments.map(HomeCachedDraftAttachment.init), for: id)
    }

    public func scrollAnchor(for id: ConversationID) -> HomeScrollAnchor? { viewCache.scrollAnchors[id] }

    /// Where the reader is; nil when at the bottom.
    public func setScrollAnchor(_ anchor: HomeScrollAnchor?, for id: ConversationID) {
        viewCache.setScrollAnchor(anchor, for: id)
    }

    /// Writes the coalesced cache batch now (app quit), without stopping.
    public func flushCache() {
        viewCache.flush()
    }

    /// Shows what the cache holds before the owner answers.
    func restoreCache() {
        guard let snapshot = cache?.load() else { return }
        viewCache.restore(snapshot) {
            mirror.seed(snapshot)
            seeded = Set(mirror.conversations.keys)
            me = mirror.me
            // A draft's files are this client's own, like a prepare's: the prune keeps them, and
            // they count as used now for a store on the same directory that does not hold them.
            for attachment in viewCache.draftAttachments.values.joined().compactMap(\.local) {
                localFiles[attachment.ref.hash] = attachment.files
                AttachmentMedia.touch(attachment.fileURL.deletingLastPathComponent())
            }
            for send in snapshot.sends { log.restore(send.intent, failed: send.failed) }
            rebuildRows()
            for id in Set(snapshot.windows.keys).union(snapshot.sends.map(\.conversation)) { bumpTranscript(id) }
        }
    }

    /// Writes the cache soon (coalesced), or at once with no delay.
    func scheduleCacheWrite() {
        viewCache.scheduleWrite()
    }

    /// The owner's state as the mirror has it (the view cache adds the client's own state).
    func ownerCacheSnapshot() -> HomeCacheSnapshot {
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me ?? mirror.me
        snapshot.conversations = mirror.conversations.values.sorted { $0.id.rawValue < $1.id.rawValue }
        snapshot.windows = mirror.windows.compactMapValues { window in
            window.messages.isEmpty ? nil : Array(window.messages.suffix(HomeCache.windowLimit))
        }
        snapshot.sends = log.entries.compactMap(HomeCachedSend.init)
        return snapshot
    }

    /// `Caches/cmux-home-blobs`.
    public nonisolated static var defaultBlobCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("cmux-home-blobs", isDirectory: true)
    }
}
