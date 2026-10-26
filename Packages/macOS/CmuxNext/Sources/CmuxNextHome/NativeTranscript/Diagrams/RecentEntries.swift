/// A least-recently-used map whose entries carry a cost (pixel bytes, text bytes) and a last use
/// time, for ``OndineMermaidRenderer``'s render and image caches.
///
/// A read marks its entry used; ``trim(toCost:keepingUsedAfter:)`` and
/// ``trim(toCount:keepingUsedAfter:)`` drop the least recently used entries down to a bound, and
/// can keep the entries used after a time (a memory consumer's working set, ``MemoryLimit/workingSet``).
/// A trim under its bound is O(1); one that drops entries orders them once.
///
/// ```swift
/// var images = RecentEntries<String, CGImage>()
/// images.set(image, cost: image.bytesPerRow * image.height, for: key, at: now)
/// images.trim(toCost: 32 << 20, keepingUsedAfter: nil)
/// ```
nonisolated struct RecentEntries<Key: Hashable, Value> {
    private struct Slot {
        var value: Value
        var cost: Int
        var lastUse: Duration
        var order: UInt64
    }

    private var slots: [Key: Slot] = [:]
    private var nextOrder: UInt64 = 0
    /// The sum of the entries' costs.
    private(set) var cost = 0

    /// How many entries it holds.
    var count: Int { slots.count }

    /// The value for `key`, marked used at `now`; nil when it holds none.
    mutating func value(for key: Key, at now: Duration) -> Value? {
        guard var slot = slots[key] else { return nil }
        slot.lastUse = now
        slot.order = takeOrder()
        slots[key] = slot
        return slot.value
    }

    /// Stores `value` for `key` as the most recently used entry, replacing one there.
    mutating func set(_ value: Value, cost: Int, for key: Key, at now: Duration) {
        let cost = max(cost, 0)
        if let old = slots.updateValue(Slot(value: value, cost: cost, lastUse: now, order: takeOrder()), forKey: key) {
            self.cost -= old.cost
        }
        self.cost += cost
    }

    /// Drops the least recently used entries until their costs sum to at most `bound`, keeping
    /// every entry last used after `cutoff` (nil keeps none: the bound is hard).
    mutating func trim(toCost bound: Int, keepingUsedAfter cutoff: Duration?) {
        guard cost > bound else { return }
        for key in oldestFirst(droppable: cutoff) {
            guard cost > bound else { return }
            if let slot = slots.removeValue(forKey: key) { cost -= slot.cost }
        }
    }

    /// Drops the least recently used entries until at most `bound` are left, keeping every entry
    /// last used after `cutoff` (nil keeps none: the bound is hard).
    mutating func trim(toCount bound: Int, keepingUsedAfter cutoff: Duration?) {
        guard slots.count > bound else { return }
        for key in oldestFirst(droppable: cutoff) {
            guard slots.count > bound else { return }
            if let slot = slots.removeValue(forKey: key) { cost -= slot.cost }
        }
    }

    /// The keys a trim may drop, least recently used first: all of them, or those last used at or before `cutoff`.
    private func oldestFirst(droppable cutoff: Duration?) -> [Key] {
        slots.filter { entry in cutoff.map { entry.value.lastUse <= $0 } ?? true }
            .sorted { $0.value.order < $1.value.order }
            .map(\.key)
    }

    private mutating func takeOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }
}
