/// Which terminal surfaces stay alive (architecture.md section 4): every
/// visible tab, plus the most recently hidden ones up to `capacity`. A hidden
/// tab beyond that loses its surface and re-attaches from the daemon replay
/// when shown again.
public struct SurfaceRetention<Key: Hashable & Sendable>: Sendable {
    public private(set) var capacity: Int
    public private(set) var visible: Set<Key> = []
    /// Hidden but retained, least recently hidden first.
    public private(set) var recent: [Key] = []
    /// When each key of ``recent`` was hidden (the memory release keeps the last 2 s: its working set).
    private var hiddenAt: [Key: ContinuousClock.Instant] = [:]

    public init(capacity: Int = 8) {
        self.capacity = max(0, capacity)
    }

    public func isRetained(_ key: Key) -> Bool {
        visible.contains(key) || recent.contains(key)
    }

    /// When the least recently hidden key (the next one a smaller capacity evicts) was hidden.
    public var leastRecentlyHiddenAt: ContinuousClock.Instant? {
        recent.first.flatMap { hiddenAt[$0] }
    }

    /// Marks `key` shown or hidden at `now`. Returns the keys whose surfaces
    /// must be destroyed now.
    @discardableResult
    public mutating func setVisible(_ key: Key, _ isVisible: Bool, at now: ContinuousClock.Instant = .now) -> [Key] {
        if isVisible {
            visible.insert(key)
            recent.removeAll { $0 == key }
            hiddenAt[key] = nil
            return []
        }
        guard visible.remove(key) != nil || !recent.contains(key) else { return [] }
        recent.removeAll { $0 == key }
        recent.append(key)
        hiddenAt[key] = now
        return trim()
    }

    /// Changes the capacity; returns the least recently hidden keys that no
    /// longer fit.
    public mutating func setCapacity(_ capacity: Int) -> [Key] {
        self.capacity = max(0, capacity)
        return trim()
    }

    /// Forgets `key` (its tab closed).
    public mutating func remove(_ key: Key) {
        visible.remove(key)
        recent.removeAll { $0 == key }
        hiddenAt[key] = nil
    }

    /// Evicts the least recently hidden keys past `capacity`.
    private mutating func trim() -> [Key] {
        guard recent.count > capacity else { return [] }
        let evicted = Array(recent.prefix(recent.count - capacity))
        recent.removeFirst(evicted.count)
        for key in evicted { hiddenAt[key] = nil }
        return evicted
    }
}
