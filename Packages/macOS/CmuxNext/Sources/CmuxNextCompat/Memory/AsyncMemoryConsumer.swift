/// A memory consumer whose state lives off the main actor: an actor (a thumbnail cache), or a class
/// that keeps its state in a `Mutex` (an idempotency cache, a login environment cache).
///
/// The memory coordinator calls consumers on the main actor. An ``AsyncMemoryConsumerRegistration``
/// posts each of those calls here instead, so the cache keeps its state where it is and the main
/// actor pays one enqueue. An actor gets both calls on its own executor; a `Mutex` class gets them on
/// the cooperative pool. Each call returns what the consumer holds afterwards, which the registration
/// keeps for the memory report (async consumers report their last value).
///
/// The calls mean what they mean on ``MemoryConsumer``: ``updateMemoryLimit(_:)`` lowers caps and
/// frees nothing (Chrome's `OnUpdateMemoryLimit()`); ``releaseMemory(downTo:)`` frees what is above
/// the limit (Chrome's `OnReleaseMemory()`). It runs off the main thread, so it is not cut into slices.
///
/// ```swift
/// actor ThumbnailCache: AsyncMemoryConsumer {
///     func updateMemoryLimit(_ limit: MemoryLimit) -> MemoryUsage? {
///         byteCap = limit.scale(fullBytes)
///         return usage
///     }
///
///     func releaseMemory(downTo limit: MemoryLimit) -> MemoryUsage? {
///         evict(downTo: limit.scale(fullBytes))
///         return usage
///     }
/// }
/// ```
public protocol AsyncMemoryConsumer: AnyObject, Sendable {
    /// Takes the limit the consumer may keep from now on. Lower caps here; free nothing.
    ///
    /// - Parameter limit: The share of the consumer's full size it may keep.
    /// - Returns: What the consumer holds now, or nil when it cannot tell.
    func updateMemoryLimit(_ limit: MemoryLimit) async -> MemoryUsage?

    /// Frees what is above `limit`.
    ///
    /// - Parameter limit: The limit to release down to.
    /// - Returns: What the consumer holds now, or nil when it cannot tell.
    func releaseMemory(downTo limit: MemoryLimit) async -> MemoryUsage?
}
