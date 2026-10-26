/// Where ``MemoryConsumerRegistration`` adds its consumer: the memory coordinator in the app
/// (`CmuxNextMemory`, made at the composition root and injected), a fake in tests.
///
/// Chrome's `base/memory_coordinator/memory_consumer_registry.h`, without the process-wide
/// singleton: every owner that registers a consumer is given the registry. There is no remove call:
/// a registration that is cancelled or released marks its entry released (on any thread), and the
/// registry calls only ``MemoryConsumerEntry/liveConsumer`` and drops released entries whenever it
/// adds one or walks its entries, so its list stays bounded by the live consumers.
@MainActor
public protocol MemoryConsumerRegistry: AnyObject {
    /// Adds `entry` and calls its consumer's ``MemoryConsumer/updateMemoryLimit(_:)`` with the
    /// current limit for its traits before it returns, so a new consumer never runs a turn at the
    /// wrong size. Drops released entries first.
    ///
    /// - Parameter entry: The registration's entry.
    func addMemoryConsumer(_ entry: MemoryConsumerEntry)
}
