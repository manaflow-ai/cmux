/// Something that holds memory it can give back when the system is short: a cache, a pool of hidden
/// pages, saved render state.
///
/// A port of Chrome's `base/memory_coordinator/memory_consumer.h`. The memory coordinator
/// (`CmuxNextMemory`) owns the policy; a consumer only answers three calls, all on the main actor:
///
/// - ``updateMemoryLimit(_:)`` says how much the consumer may keep from now on. It must not free
///   anything (Chrome's `OnUpdateMemoryLimit()`): it lowers caps so the consumer stops growing.
/// - ``releaseMemory(within:)`` frees what is above the limit, in one bounded slice (Chrome's
///   `OnReleaseMemory()`, cut into turns so it never takes a frame). It only unlinks: the last
///   references go to the coordinator's release sink, which drops them off the main thread.
/// - ``memoryUsage`` reports what it holds now, from counters it keeps (nil when it cannot tell).
///
/// A consumer registers through ``MemoryConsumerRegistration`` with its name and
/// ``MemoryConsumerTraits``, and gets the current limit at once, before the registration's init
/// returns. Consumers on other actors use an asynchronous registration that posts each call to their
/// actor (Chrome's `base/memory_coordinator/async_memory_consumer_registration.h`).
///
/// ```swift
/// final class PreviewImageCache: MemoryConsumer {
///     private var registration: MemoryConsumerRegistration?
///
///     init(registry: any MemoryConsumerRegistry) {
///         registration = MemoryConsumerRegistration(
///             name: "preview-images", traits: .init(...), consumer: self, registry: registry)
///     }
///
///     func updateMemoryLimit(_ limit: MemoryLimit) { byteCap = limit.scale(fullBytes) }
///     func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress { ... }
///     var memoryUsage: MemoryUsage? { MemoryUsage(footprintBytes: bytes, entries: count) }
/// }
/// ```
@MainActor
public protocol MemoryConsumer: AnyObject {
    /// Takes the limit the consumer may keep from now on. Lower caps here; free nothing.
    ///
    /// - Parameter limit: The share of the consumer's full size it may keep.
    func updateMemoryLimit(_ limit: MemoryLimit)

    /// Frees what is above `slice.limit`, stopping when `slice.isExpired`.
    ///
    /// - Parameter slice: The limit to release down to and the time this turn may take.
    /// - Returns: ``MemoryReleaseProgress/done`` when the consumer is at or under the limit,
    ///   ``MemoryReleaseProgress/more`` when the slice ran out first, ``MemoryReleaseProgress/yield``
    ///   when it freed its one item for this frame and leaves the rest of the slice to the others.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress

    /// What the consumer holds now, or nil when it cannot tell.
    var memoryUsage: MemoryUsage? { get }
}
