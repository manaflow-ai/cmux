public import CmuxNextCompat

/// The registered memory consumers of one process, as the memory coordinator keeps them (Chrome's
/// `base/memory_coordinator/memory_consumer_registry.h` list). Each stored `Record` is one
/// registration's ``MemoryConsumerEntry`` with what its owner keeps beside it (the coordinator's
/// limit and release state), so the drop rule below has one owner. The order is registration order,
/// or the owner's order (``init(orderedBy:)``) with equal records in registration order; it is set
/// on add, so a walk never sorts.
///
/// A registration that is cancelled or released only marks its entry released (it may go on any
/// thread), so the list drops released records each time it adds one and each time it hands out
/// ``liveRecords()`` or ``liveEntries()``: its size stays bounded by the live consumers plus the
/// ones released since the last add or walk, with no timer.
///
/// ```swift
/// consumers.add(entry)
/// for entry in consumers.liveEntries() { entry.liveConsumer?.updateMemoryLimit(limit(for: entry.traits)) }
/// ```
@MainActor
public final class MemoryConsumerList<Record: MemoryConsumerListRecord> {
    private var records: [Record] = []
    private let areInIncreasingOrder: (@MainActor (Record, Record) -> Bool)?

    /// Makes an empty list in registration order.
    public init() {
        areInIncreasingOrder = nil
    }

    /// Makes an empty list kept in `areInIncreasingOrder`; equal records keep registration order.
    ///
    /// - Parameter areInIncreasingOrder: Whether the first record goes before the second.
    public init(orderedBy areInIncreasingOrder: @escaping @MainActor (Record, Record) -> Bool) {
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050); the
    // records need no main-actor cleanup.
    nonisolated deinit {}

    /// Adds `record` after dropping released records: last in registration order, or after every
    /// record that does not go after it in the owner's order.
    ///
    /// - Parameter record: A new registration's record.
    public func add(_ record: Record) {
        dropReleased()
        guard let areInIncreasingOrder else {
            records.append(record)
            return
        }
        let index = records.firstIndex { areInIncreasingOrder(record, $0) } ?? records.endIndex
        records.insert(record, at: index)
    }

    /// Drops released records and returns the rest, in the list's order. The result is a copy,
    /// so a consumer may register or cancel while the caller walks it; the caller still checks
    /// ``MemoryConsumerEntry/liveConsumer`` before each call.
    ///
    /// - Returns: The live records.
    public func liveRecords() -> [Record] {
        dropReleased()
        return records
    }

    /// Drops released records and returns the entries of the rest, in the list's order.
    ///
    /// - Returns: The live entries.
    public func liveEntries() -> [MemoryConsumerEntry] {
        liveRecords().map { $0.entry }
    }

    /// How many records the list holds now, released ones not yet dropped included.
    public var storedCount: Int {
        records.count
    }

    private func dropReleased() {
        records.removeAll { !$0.entry.isLive }
    }
}

/// What a ``MemoryConsumerList`` stores: one registration's entry, plus whatever the list's owner
/// keeps with it. An entry is its own record when the owner keeps nothing else.
@MainActor
public protocol MemoryConsumerListRecord {
    /// The registration's entry; the list drops the record once the entry is no longer live.
    var entry: MemoryConsumerEntry { get }
}

extension MemoryConsumerEntry: MemoryConsumerListRecord {
    public var entry: MemoryConsumerEntry {
        self
    }
}
