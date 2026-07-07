import Foundation

extension SessionPersistencePolicy {
    /// Maximum number of per-display-configuration frames a window remembers.
    /// An LRU ring — the least-recently-used configuration is evicted past this.
    static let maxConfigFramesPerWindow: Int = 8
}

struct SessionDisplaySnapshot: Codable, Sendable, Equatable {
    var displayID: UInt32?
    /// Stable per-physical-display identity (see `NSScreen.cmuxStableDisplayKey`).
    /// Optional and additive so older persisted snapshots decode unchanged.
    var stableID: String?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

/// One remembered window frame for a specific display configuration. A window
/// keeps a small LRU ring of these so it can return to where it was on each
/// monitor arrangement the user switches between (issue #2135).
struct SessionConfigFrameEntry: Codable, Sendable, Equatable {
    /// The display-configuration signature this frame belongs to
    /// (see `DisplayConfigurationSignature`).
    var signature: String
    var frame: SessionRectSnapshot
    var display: SessionDisplaySnapshot?
    /// Wall-clock of the last capture, for LRU eviction.
    var lastUsedAt: TimeInterval
}

enum SessionConfigFramePolicy {
    /// Deduplicates by signature, keeps the newest entry per signature, and
    /// trims to the LRU cap.
    static func sanitized(
        _ entries: [SessionConfigFrameEntry],
        limit: Int = SessionPersistencePolicy.maxConfigFramesPerWindow
    ) -> [SessionConfigFrameEntry] {
        var seen = Set<String>()
        var result: [SessionConfigFrameEntry] = []
        for entry in entries.sorted(by: { $0.lastUsedAt > $1.lastUsedAt })
        where seen.insert(entry.signature).inserted {
            result.append(entry)
            if result.count >= limit { break }
        }
        return result
    }

    /// Upserts `entry` into `existing`, keyed by signature, then trims to the
    /// most-recently-used `limit` entries. Pure so it can be unit-tested without
    /// live displays.
    ///
    /// - The entry for a matching signature is replaced (a window's latest frame
    ///   for a configuration wins).
    /// - Ordering/eviction is by `lastUsedAt`, most-recent first, so the
    ///   least-recently-used configuration is dropped once the ring is full.
    static func merged(
        _ existing: [SessionConfigFrameEntry],
        upserting entry: SessionConfigFrameEntry,
        limit: Int = SessionPersistencePolicy.maxConfigFramesPerWindow
    ) -> [SessionConfigFrameEntry] {
        var next = existing.filter { $0.signature != entry.signature }
        next.append(entry)
        return sanitized(next, limit: limit)
    }

    /// The remembered frame entry for `signature`, if present.
    static func entry(
        for signature: String,
        in entries: [SessionConfigFrameEntry]?
    ) -> SessionConfigFrameEntry? {
        entries?.first { $0.signature == signature }
    }
}
