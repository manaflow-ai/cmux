/// Which terminal surfaces stay alive (architecture.md section 4): every
/// visible tab, plus the most recently hidden ones up to `capacity`. A hidden
/// tab beyond that loses its surface and re-attaches from the daemon replay
/// when shown again.
public struct SurfaceRetention<Key: Hashable & Sendable>: Sendable {
    public private(set) var capacity: Int
    public private(set) var visible: Set<Key> = []
    /// Hidden but retained, least recently hidden first.
    public private(set) var recent: [Key] = []

    public init(capacity: Int = 8) {
        self.capacity = max(0, capacity)
    }

    public func isRetained(_ key: Key) -> Bool {
        visible.contains(key) || recent.contains(key)
    }

    /// Marks `key` shown or hidden. Returns the keys whose surfaces must be
    /// destroyed now.
    @discardableResult
    public mutating func setVisible(_ key: Key, _ isVisible: Bool) -> [Key] {
        if isVisible {
            visible.insert(key)
            recent.removeAll { $0 == key }
            return []
        }
        guard visible.remove(key) != nil || !recent.contains(key) else { return [] }
        recent.removeAll { $0 == key }
        recent.append(key)
        guard recent.count > capacity else { return [] }
        let evicted = Array(recent.prefix(recent.count - capacity))
        recent.removeFirst(evicted.count)
        return evicted
    }

    /// Changes the capacity; returns the least recently hidden keys that no
    /// longer fit.
    public mutating func setCapacity(_ capacity: Int) -> [Key] {
        self.capacity = max(0, capacity)
        guard recent.count > self.capacity else { return [] }
        let evicted = Array(recent.prefix(recent.count - self.capacity))
        recent.removeFirst(evicted.count)
        return evicted
    }

    /// Forgets `key` (its tab closed).
    public mutating func remove(_ key: Key) {
        visible.remove(key)
        recent.removeAll { $0 == key }
    }
}
