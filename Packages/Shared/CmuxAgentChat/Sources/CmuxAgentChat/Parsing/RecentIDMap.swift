/// A fixed-size FIFO map for identities whose duplicate reports arrive nearby.
///
/// Claude streams several reports for one response, so retained identities
/// keep their latest value and can be upgraded until they leave the recent
/// window. Updating an existing key does not change its insertion position.
struct RecentIDMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var insertionOrder: [Key] = []
    private var nextEvictionIndex = 0

    /// The number of identities currently retained.
    var count: Int { values.count }

    /// Creates an empty recent-identity map.
    ///
    /// - Parameter capacity: Maximum distinct identities to retain.
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        insertionOrder.reserveCapacity(capacity)
    }

    /// Returns the retained value for an identity.
    ///
    /// - Parameter key: Identity to look up.
    /// - Returns: Its value while retained, otherwise `nil`.
    func value(forKey key: Key) -> Value? {
        values[key]
    }

    /// Stores a value, evicting the oldest distinct identity at capacity.
    ///
    /// - Parameters:
    ///   - value: Value to retain.
    ///   - key: Identity associated with the value.
    mutating func setValue(_ value: Value, forKey key: Key) {
        if values[key] != nil {
            values[key] = value
            return
        }
        if insertionOrder.count < capacity {
            insertionOrder.append(key)
        } else {
            let evicted = insertionOrder[nextEvictionIndex]
            values.removeValue(forKey: evicted)
            insertionOrder[nextEvictionIndex] = key
            nextEvictionIndex = (nextEvictionIndex + 1) % capacity
        }
        values[key] = value
    }
}
