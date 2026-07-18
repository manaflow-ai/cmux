/// A small value-type least-recently-used cache for artifact infrastructure.
public struct ChatArtifactLRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let access: UInt64
    }

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var accessCounter: UInt64 = 0

    /// Number of currently retained entries.
    public var count: Int { entries.count }

    /// Creates a bounded cache.
    ///
    /// - Parameter capacity: Maximum retained entry count.
    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Returns and marks a value as most recently used.
    ///
    /// - Parameter key: Cache identity to look up.
    /// - Returns: The retained value, or `nil`.
    public mutating func value(forKey key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        accessCounter &+= 1
        entries[key] = Entry(value: entry.value, access: accessCounter)
        return entry.value
    }

    /// Inserts or replaces a value and evicts the least recently used entry.
    ///
    /// - Parameters:
    ///   - value: Value to retain.
    ///   - key: Cache identity for the value.
    public mutating func insert(_ value: Value, forKey key: Key) {
        guard capacity > 0 else {
            entries.removeAll(keepingCapacity: false)
            return
        }
        accessCounter &+= 1
        entries[key] = Entry(value: value, access: accessCounter)
        while entries.count > capacity,
              let leastRecent = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: leastRecent)
        }
    }
}
