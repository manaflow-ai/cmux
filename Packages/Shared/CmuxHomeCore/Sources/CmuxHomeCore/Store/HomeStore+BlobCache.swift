import Foundation

// HomeStore's blob cache pruning: crash leftovers, old blobs, and the
// size cap, never touching blobs a pending send uses.
extension HomeStore {
    // MARK: Blob cache

    /// The cache grew (a prepare wrote into it): one prune
    /// `blobCachePruneInterval` from now, unless one is already due. Nothing
    /// before `start` (its pass prunes) or after `stop`.
    func scheduleBlobCachePrune() {
        guard eventTask != nil, !stopped, pruneDeadline == nil else { return }
        let clock = self.clock
        let interval = Self.blobCachePruneInterval
        // task-owner: the one prune due after the cache grew; `stop` cancels it
        pruneDeadline = Task { [weak self] in
            // wakeup-allow: deadline one prune `blobCachePruneInterval` after a prepare grew the cache; armed
            // again only by the next prepare after it ran, or by a pass a running prepare made skip
            do { try await clock.sleep(for: interval, tolerance: HomeWakeLeeway(delay: interval).tolerance) } catch { return }
            guard let self, !self.stopped else { return }
            self.pruneDeadline = nil
            await self.pruneBlobCache()
        }
    }

    /// Prunes the blob cache (at `start`, then `blobCachePruneInterval`
    /// after a prepare grew it or after a running prepare made a pass
    /// skip): temp files left by a crash,
    /// blobs older than `blobCacheMaxAge`, then the least recently used
    /// blobs over `blobCacheMaxBytes`. Never deletes a blob that a pending
    /// send or this session's prepared attachments use.
    public func pruneBlobCache(now: Date = Date()) async {
        if let running = pruning {
            await running.value
            return
        }
        // A prepare may be reusing a blob it has not registered yet, and it
        // may fail without arming a prune: the skipped pass stays due.
        guard preparing == 0 else {
            scheduleBlobCachePrune()
            return
        }
        var keep = Set<String>()
        func add(_ ref: AttachmentRef) {
            keep.insert(ref.hash)
            if let poster = ref.posterHash { keep.insert(poster) }
            if let preview = ref.preview?.hash { keep.insert(preview) }
        }
        for job in uploads.values { job.attachments.forEach { add($0.ref) } }
        for entry in log.entries {
            guard case .sendMessage(_, let parts, _, _) = entry.intent.op else { continue }
            for part in parts { keep.formUnion(part.blobHashes) }
        }
        for (hash, files) in localFiles {
            keep.insert(hash)
            if let poster = files.posterHash { keep.insert(poster) }
            if let preview = files.previewHash { keep.insert(preview) }
        }
        let root = blobCacheDirectory
        let tempsBefore = createdAt
        let willDelete = pruneWillDelete
        // The pass clears `pruning` itself, on the main actor, the moment
        // it ends: a waiting prepare never sees a finished pass (awaiting
        // a finished task does not suspend, so it would spin).
        let pass = Task { [weak self] in
            await Self.pruneBlobCache(at: root, keeping: keep, now: now, maxAge: Self.blobCacheMaxAge,
                                      maxBytes: Self.blobCacheMaxBytes, tempsBefore: tempsBefore, willDelete: willDelete)
            self?.pruning = nil
        }
        pruning = pass
        await pass.value
    }

    /// One pass over `<root>/<hash>/`: deletes `.incoming-*` files older
    /// than `tempsBefore`, blob directories not in `keep` unused for
    /// `maxAge`, then the least recently used ones not in `keep` while the
    /// cache is over `maxBytes`. "Used" is the directory's modification
    /// date, which a local fetch refreshes.
    @concurrent
    public nonisolated static func pruneBlobCache(at root: URL, keeping keep: Set<String>, now: Date,
                                                  maxAge: TimeInterval, maxBytes: Int, tempsBefore: Date,
                                                  willDelete: (@Sendable (String) async -> Void)? = nil) async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        var blobs: [(name: String, url: URL, used: Date, bytes: Int)] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if name.hasPrefix(".incoming-") {
                if modified < tempsBefore { try? fm.removeItem(at: url) }
                continue
            }
            guard values?.isDirectory == true else { continue }
            blobs.append((name, url, modified, AttachmentMedia.directorySize(url)))
        }
        var total = blobs.reduce(0) { $0 + $1.bytes }
        for blob in blobs.sorted(by: { $0.used < $1.used }) where !keep.contains(blob.name) {
            guard now.timeIntervalSince(blob.used) > maxAge || total > maxBytes else { continue }
            await willDelete?(blob.name)
            try? fm.removeItem(at: blob.url)
            total -= blob.bytes
        }
    }
}
