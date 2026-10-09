import Foundation

// HomeStore's client view state and durable cache: drafts, scroll anchors,
// and restoring and writing the HomeCache snapshot.
extension HomeStore {
    /// The unsent text of a conversation's compose field.
    public func draft(for id: ConversationID) -> String? { drafts[id] }

    /// Keeps the compose field's text; empty text clears it.
    public func setDraft(_ text: String, for id: ConversationID) {
        let value: String? = text.isEmpty ? nil : text
        guard drafts[id] != value else { return }
        drafts[id] = value
        scheduleCacheWrite()
    }

    public func scrollAnchor(for id: ConversationID) -> HomeScrollAnchor? { scrollAnchors[id] }

    /// Where the reader is; nil when at the bottom.
    public func setScrollAnchor(_ anchor: HomeScrollAnchor?, for id: ConversationID) {
        guard scrollAnchors[id] != anchor else { return }
        scrollAnchors[id] = anchor
        scheduleCacheWrite()
    }

    /// Writes the coalesced cache batch now (app quit), without stopping.
    public func flushCache() {
        cacheWrite?.cancel()
        cacheWrite = nil
        writeCache()
    }

    /// Shows what the cache holds before the owner answers.
    func restoreCache() {
        guard let snapshot = cache?.load() else { return }
        restoringCache = true
        defer { restoringCache = false }
        mirror.seed(snapshot)
        me = mirror.me
        drafts = snapshot.drafts
        scrollAnchors = snapshot.scroll
        for send in snapshot.sends { log.restore(send.intent, failed: send.failed) }
        rebuildRows()
        for id in Set(snapshot.windows.keys).union(snapshot.sends.map(\.conversation)) { bumpTranscript(id) }
    }

    /// Writes the cache soon (coalesced), or at once with no delay.
    func scheduleCacheWrite() {
        guard cache != nil, !restoringCache else { return }
        guard cacheWriteDelay > .zero else { return writeCache() }
        guard cacheWrite == nil else { return }
        let clock = clock
        let delay = cacheWriteDelay
        // task-owner: one coalesced cache write; cancelled by stop, which writes at once
        cacheWrite = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.cacheWrite = nil
            self?.writeCache()
        }
    }

    /// The owner's state as the mirror has it, plus the client's own state.
    func writeCache() {
        guard let cache else { return }
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me ?? mirror.me
        snapshot.conversations = mirror.conversations.values.sorted { $0.id.rawValue < $1.id.rawValue }
        snapshot.windows = mirror.windows.compactMapValues { window in
            window.messages.isEmpty ? nil : Array(window.messages.suffix(HomeCache.windowLimit))
        }
        snapshot.sends = log.entries.compactMap(HomeCachedSend.init)
        snapshot.drafts = drafts
        snapshot.scroll = scrollAnchors
        try? cache.save(snapshot)
    }

    /// `Caches/cmux-home-blobs`.
    public nonisolated static var defaultBlobCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("cmux-home-blobs", isDirectory: true)
    }
}
