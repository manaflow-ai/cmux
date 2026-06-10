import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


// MARK: - Directory snapshot cache
extension SessionIndexStore {
    private static let directorySnapshotCacheCapacity = 16

    /// Return a cached or freshly-built merged snapshot for a cwd-scoped
    /// directory. Used by the Show-more popover's empty-query scroll
    /// path: the popover slices this array in memory instead of asking
    /// the store for more pages on every scroll, eliminating the O(n²)
    /// repeated-refetch-and-merge behavior.
    func loadDirectorySnapshot(cwd: String?) async -> DirectorySnapshot {
        let key = cwd ?? ""
        if let cached = touchDirectorySnapshotLRU(key) {
            return cached
        }

        let generation = directorySnapshotGeneration
        let bag = ErrorBag()
        // The per-agent loaders interpret `cwdFilter == nil` as "no filter,
        // return all entries". When `cwd` is nil here we specifically mean
        // the "(no folder)" bucket — entries that genuinely have no cwd.
        // Fetch unfiltered and post-filter locally to preserve that scope.
        let noFolderScope = (cwd == nil) || ((cwd ?? "").isEmpty)
        let cwdFilter = noFolderScope ? nil : cwd
        // Large limit so every per-agent loader returns all matching rows.
        // Claude's `searchMaxFiles` cap still applies (currently 1500); if
        // anyone has more Claude sessions in a single cwd we'll bump it.
        let bigLimit = 10_000
        let order = await Self.defaultAgentOrder(workingDirectory: cwdFilter)
        var merged = await Self.loadAgents(
            order.agents,
            registry: order.registry,
            needle: "",
            cwdFilter: cwdFilter,
            offset: 0,
            limit: bigLimit,
            errorBag: bag
        )
        if Task.isCancelled {
            return DirectorySnapshot(cwd: key, entries: [], errors: [])
        }
        if noFolderScope {
            merged = merged.filter { ($0.cwd ?? "").isEmpty }
        }
        let sorted = merged.sorted { $0.modified > $1.modified }
        let snapshot = DirectorySnapshot(cwd: key, entries: sorted, errors: bag.snapshot())
        // Only cache this result if no `reload()` raced in while the
        // build was running. Otherwise the caller gets a fresh snapshot
        // but the cache stays invalidated; the next open will rebuild.
        if generation == directorySnapshotGeneration {
            storeDirectorySnapshot(key: key, snapshot: snapshot)
        }
        return snapshot
    }

    private func touchDirectorySnapshotLRU(_ key: String) -> DirectorySnapshot? {
        guard let cached = directorySnapshotCache[key] else { return nil }
        if let idx = directorySnapshotLRU.firstIndex(of: key) {
            directorySnapshotLRU.remove(at: idx)
        }
        directorySnapshotLRU.append(key)
        return cached
    }

    private func storeDirectorySnapshot(key: String, snapshot: DirectorySnapshot) {
        if directorySnapshotCache[key] == nil,
           directorySnapshotCache.count >= Self.directorySnapshotCacheCapacity,
           let oldestKey = directorySnapshotLRU.first {
            directorySnapshotCache.removeValue(forKey: oldestKey)
            directorySnapshotLRU.removeFirst()
        }
        directorySnapshotCache[key] = snapshot
        if let idx = directorySnapshotLRU.firstIndex(of: key) {
            directorySnapshotLRU.remove(at: idx)
        }
        directorySnapshotLRU.append(key)
    }

    func invalidateDirectorySnapshots() {
        directorySnapshotCache.removeAll()
        directorySnapshotLRU.removeAll()
    }

    func normalizedDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var path = (value as NSString).standardizingPath
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: - Scanning

}
