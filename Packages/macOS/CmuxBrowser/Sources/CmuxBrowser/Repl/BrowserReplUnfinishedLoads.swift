/// The resource loads of one tab that have started and not finished, with
/// what the REPL driver reported for each (its request, then its response),
/// so the load's last event can repeat it.
///
/// A page decides how many loads it leaves unfinished (requests that never
/// get an answer) and how long their URLs and headers are, so the table is
/// bounded: past ``maximumLoads`` loads or ``maximumBytes`` bytes the
/// oldest are dropped, and a load larger than the whole budget is not held.
/// A dropped load's end says so (``finish(_:)``), for the most recent
/// ``maximumDroppedRemembered`` dropped loads.
public struct BrowserReplUnfinishedLoads<Value> {
    /// The most loads held at once.
    public static var maximumLoads: Int { 1_000 }
    /// The most bytes (as the caller counts them) held at once, 8 MiB.
    public static var maximumBytes: Int { 8 << 20 }
    /// How many dropped loads are remembered as dropped.
    public static var maximumDroppedRemembered: Int { 4_096 }

    private var entries: [UInt64: (value: Value, bytes: Int)] = [:]
    /// Load ids in the order they started; ids no longer held are skipped
    /// and compacted away.
    private var order: [UInt64] = []
    private var orderStart = 0
    private var bytes = 0
    private var dropped: Set<UInt64> = []
    private var droppedOrder: [UInt64] = []

    public init() {}

    /// How many loads are held.
    public var count: Int { entries.count }

    /// Holds `value`, `bytes` long, for load `id`, which just started.
    public mutating func start(_ id: UInt64, _ value: Value, bytes size: Int) {
        if let previous = entries.removeValue(forKey: id) { bytes -= previous.bytes }
        guard size <= Self.maximumBytes else {
            markDropped(id)
            return
        }
        entries[id] = (value, size)
        bytes += size
        order.append(id)
        dropOldest(keeping: id)
    }

    /// What is held for load `id`, or nil.
    public func value(for id: UInt64) -> Value? {
        entries[id]?.value
    }

    /// Replaces what is held for load `id` with `value`, now `bytes` long.
    /// A load no longer held stays dropped.
    public mutating func update(_ id: UInt64, _ value: Value, bytes size: Int) {
        guard let previous = entries[id] else { return }
        guard size <= Self.maximumBytes else {
            entries[id] = nil
            bytes -= previous.bytes
            markDropped(id)
            return
        }
        entries[id] = (value, size)
        bytes += size - previous.bytes
        dropOldest(keeping: id)
    }

    /// Forgets load `id`, which finished or failed, and returns what was
    /// held for it, and whether it was dropped while it ran.
    public mutating func finish(_ id: UInt64) -> (value: Value?, dropped: Bool) {
        if let entry = entries.removeValue(forKey: id) {
            bytes -= entry.bytes
            compactOrder()
            return (entry.value, false)
        }
        return (nil, dropped.remove(id) != nil)
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        orderStart = 0
        bytes = 0
        dropped.removeAll()
        droppedOrder.removeAll()
    }

    /// Drops the oldest loads other than `id` while the table is over a bound.
    private mutating func dropOldest(keeping id: UInt64) {
        while entries.count > Self.maximumLoads || bytes > Self.maximumBytes, orderStart < order.count {
            let oldest = order[orderStart]
            orderStart += 1
            guard oldest != id, let entry = entries.removeValue(forKey: oldest) else {
                if oldest == id { order.append(id) }
                continue
            }
            bytes -= entry.bytes
            markDropped(oldest)
        }
        compactOrder()
    }

    /// Keeps `order` within a small multiple of the loads held.
    private mutating func compactOrder() {
        guard order.count - orderStart > 2 * max(entries.count, 64) || orderStart > 4_096 else { return }
        order = order[orderStart...].filter { entries[$0] != nil }
        orderStart = 0
    }

    private mutating func markDropped(_ id: UInt64) {
        guard dropped.insert(id).inserted else { return }
        droppedOrder.append(id)
        if droppedOrder.count > Self.maximumDroppedRemembered * 2 {
            let forgotten = droppedOrder.count - Self.maximumDroppedRemembered
            for old in droppedOrder[..<forgotten] { dropped.remove(old) }
            droppedOrder.removeFirst(forgotten)
        }
    }
}
