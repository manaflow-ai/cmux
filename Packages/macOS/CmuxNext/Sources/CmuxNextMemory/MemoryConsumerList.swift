public import CmuxNextCompat

/// The registered memory consumers of one process, in registration order, as the memory coordinator
/// keeps them (Chrome's `base/memory_coordinator/memory_consumer_registry.h` list).
///
/// A registration that is cancelled or released only marks its entry released (it may go on any
/// thread), so the list drops released entries each time it adds one and each time it hands out
/// ``liveEntries``: its size stays bounded by the live consumers plus the ones released since the
/// last add or walk, with no timer.
///
/// ```swift
/// consumers.add(entry)
/// for entry in consumers.liveEntries() { entry.liveConsumer?.updateMemoryLimit(limit(for: entry.traits)) }
/// ```
@MainActor
public struct MemoryConsumerList {
    private var entries: [MemoryConsumerEntry] = []

    /// Makes an empty list.
    public init() {}

    /// Adds `entry` after dropping released entries.
    ///
    /// - Parameter entry: A new registration's entry.
    public mutating func add(_ entry: MemoryConsumerEntry) {
        entries.removeAll { !$0.isLive }
        entries.append(entry)
    }

    /// Drops released entries and returns the rest, in registration order. The result is a copy, so
    /// a consumer may register or cancel while the caller walks it; the caller still checks
    /// ``MemoryConsumerEntry/liveConsumer`` before each call.
    ///
    /// - Returns: The live entries.
    public mutating func liveEntries() -> [MemoryConsumerEntry] {
        entries.removeAll { !$0.isLive }
        return entries
    }

    /// How many entries the list holds now, released ones not yet dropped included.
    public var storedCount: Int {
        entries.count
    }
}
