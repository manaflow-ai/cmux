/// The resource loads of one tab that have started and not finished, with
/// what the REPL driver reported for each (its request, then its response),
/// so the load's last event can repeat it.
public struct BrowserReplUnfinishedLoads<Value> {
    private var entries: [UInt64: Value] = [:]

    public init() {}

    /// How many loads are held.
    public var count: Int { entries.count }

    /// Holds `value`, `bytes` long, for load `id`, which just started.
    public mutating func start(_ id: UInt64, _ value: Value, bytes: Int) {
        entries[id] = value
    }

    /// What is held for load `id`, or nil.
    public func value(for id: UInt64) -> Value? {
        entries[id]
    }

    /// Replaces what is held for load `id` with `value`, now `bytes` long.
    public mutating func update(_ id: UInt64, _ value: Value, bytes: Int) {
        entries[id] = value
    }

    /// Forgets load `id`, which finished or failed, and returns what was
    /// held for it, and whether it was dropped while it ran.
    public mutating func finish(_ id: UInt64) -> (value: Value?, dropped: Bool) {
        (entries.removeValue(forKey: id), false)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
