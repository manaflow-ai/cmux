import Foundation

/// Per-tab/surface stash of superseded phone-banner ids whose dismiss is
/// deferred until the replacement banner push is actually queued (the phone
/// push path throttles per tab/surface; see
/// ``TerminalNotificationStore/deliverNotificationSideEffects``). Bounded per
/// key; holds opaque notification UUID strings only, never content.
struct SupersededPhoneDismissBuffer {
    private var idsByKey: [String: [String]] = [:]
    /// More superseded-but-undelivered banners than this for one tab/surface
    /// means a runaway producer; the oldest ids are evicted (their banners were
    /// already replaced on the phone by newer ones via earlier dismissals, and
    /// the reconcile sweep heals any stragglers from the tombstone ring).
    static let capacityPerKey = 64

    /// The stash key for a notification's tab/surface, mirroring the phone push
    /// throttle key.
    static func key(tabId: UUID, surfaceId: UUID?) -> String {
        "\(tabId.uuidString):\(surfaceId?.uuidString ?? "")"
    }

    /// Park superseded banner ids until the replacement push is queued.
    /// Duplicates are kept once; the oldest evicted past ``capacityPerKey``.
    mutating func stash(ids: [String], forKey key: String) {
        guard !ids.isEmpty else { return }
        var pending = idsByKey[key] ?? []
        for id in ids where !pending.contains(id) {
            pending.append(id)
        }
        if pending.count > Self.capacityPerKey {
            pending.removeFirst(pending.count - Self.capacityPerKey)
        }
        idsByKey[key] = pending
    }

    /// Take (and clear) everything stashed for the key, oldest first.
    mutating func flush(forKey key: String) -> [String] {
        idsByKey.removeValue(forKey: key) ?? []
    }

    /// Take (and clear) everything stashed under the given tab, for tab-scoped
    /// read/clear operations (after which no surface in the tab has an unread
    /// entry, so no stale banner may survive).
    mutating func flush(matchingTabId tabId: UUID) -> [String] {
        let prefix = tabId.uuidString + ":"
        var drained: [String] = []
        for key in idsByKey.keys.filter({ $0.hasPrefix(prefix) }).sorted() {
            drained.append(contentsOf: idsByKey.removeValue(forKey: key) ?? [])
        }
        return drained
    }

    /// Take (and clear) everything stashed across all keys, for clear-all /
    /// mark-all-read operations.
    mutating func flushAll() -> [String] {
        let drained = idsByKey.keys.sorted().flatMap { idsByKey[$0] ?? [] }
        idsByKey.removeAll()
        return drained
    }
}
