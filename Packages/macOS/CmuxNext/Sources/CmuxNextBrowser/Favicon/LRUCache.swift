/// A small least-recently-used map. `value(for:)` and `set` mark an entry
/// used; inserting past `capacity` drops the least recently used one.
/// O(n) in the entry count, which stays small (favicons).
public nonisolated struct LRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var values: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { values.count }

    public mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// Reads without marking the entry used.
    public func peek(_ key: Key) -> Value? { values[key] }

    public mutating func set(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) != nil {
            touch(key)
            return
        }
        order.append(key)
        if order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
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
