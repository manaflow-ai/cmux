import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


/// Process-wide cache for parsed Claude session metadata, keyed by file URL with
/// mtime as the freshness check. Avoids re-reading and re-parsing the same
/// jsonls across pagination calls. Bounded by `maxEntries` to keep memory in
/// check (LRU on insert).
final class ClaudeMetadataCache: @unchecked Sendable {
    static let shared = ClaudeMetadataCache()
    private let maxEntries = 1000
    private let lock = NSLock()
    private var entries: [URL: (mtime: Date, entry: SessionEntry)] = [:]

    func get(url: URL, mtime: Date) -> SessionEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entries[url], cached.mtime == mtime else { return nil }
        return cached.entry
    }

    func put(url: URL, mtime: Date, entry: SessionEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = (mtime, entry)
        if entries.count > maxEntries {
            // Evict ~10% (oldest mtimes) to amortize cleanup cost.
            let evictCount = entries.count / 10
            let oldestKeys = entries
                .sorted { $0.value.mtime < $1.value.mtime }
                .prefix(evictCount)
                .map(\.key)
            for k in oldestKeys { entries.removeValue(forKey: k) }
        }
    }
}

// MARK: - Drag registry

