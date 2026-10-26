// memory: consumer via its owner (a value type: the class that stores it registers the memory consumer
// and scales `limit`, as BrowserFaviconLoader's "browser-favicons" does).

/// A small least-recently-used map. `value(for:)` and `set` mark an entry
/// used; inserting past `limit` drops the least recently used ones.
/// O(n) in the entry count, which stays small (favicons).
///
/// `capacity` is its full size; `limit` is what it may keep now (a memory consumer's
/// `MemoryLimit` scaled onto `capacity`). Lowering the limit frees nothing: inserts stop
/// growing it, and the owner frees down to it with ``removeLeastRecentlyUsed()``.
public nonisolated struct LRUCache<Key: Hashable, Value> {
    /// The most entries it keeps at its full size (at least 1).
    public let capacity: Int
    /// The most entries it keeps now, 0...capacity (``capacity`` until ``setLimit(_:)``).
    public private(set) var limit: Int
    private var values: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    /// - Parameters:
    ///   - capacity: The full size, in entries (at least 1).
    ///   - limit: The entries it may keep now, clamped to 0...capacity; nil is the full size.
    public init(capacity: Int, limit: Int? = nil) {
        self.capacity = max(1, capacity)
        self.limit = min(max(0, limit ?? capacity), self.capacity)
    }

    public var count: Int { values.count }

    /// Whether it holds more entries than ``limit``.
    public var isOverLimit: Bool { values.count > limit }

    public mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// Reads without marking the entry used.
    public func peek(_ key: Key) -> Value? { values[key] }

    /// Stores `value` for `key` as the most recently used entry, then drops the least recently
    /// used ones past ``limit`` (at limit 0, `value` itself).
    ///
    /// - Returns: The values it let go: the one `value` replaced, then the evicted ones.
    @discardableResult
    public mutating func set(_ value: Value, for key: Key) -> [Value] {
        var dropped: [Value] = []
        if let old = values.updateValue(value, forKey: key) {
            dropped.append(old)
            touch(key)
        } else {
            order.append(key)
        }
        while values.count > limit, let evicted = removeLeastRecentlyUsed() {
            dropped.append(evicted)
        }
        return dropped
    }

    /// Sets how many entries it may keep from now on, clamped to 0...capacity. Frees nothing.
    public mutating func setLimit(_ entries: Int) {
        limit = min(max(0, entries), capacity)
    }

    /// Drops the least recently used entry.
    ///
    /// - Returns: Its value, or nil when it is empty.
    @discardableResult
    public mutating func removeLeastRecentlyUsed() -> Value? {
        guard !order.isEmpty else { return nil }
        return values.removeValue(forKey: order.removeFirst())
    }

    /// Calls `body` with every entry, in no particular order, without marking any used.
    public func forEach(_ body: (Key, Value) throws -> Void) rethrows {
        for (key, value) in values { try body(key, value) }
    }

    public mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        order.removeAll(where: shouldRemove)
        values = values.filter { !shouldRemove($0.key) }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
