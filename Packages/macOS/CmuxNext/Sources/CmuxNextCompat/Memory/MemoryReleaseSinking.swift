/// Where a ``MemoryConsumer`` puts what it unlinked in ``MemoryConsumer/releaseMemory(within:)``, so
/// the last reference, and the free it causes, goes off the main thread.
///
/// The memory coordinator's release sink (`CmuxNextMemory`'s `MemoryReleaseSink`, made at the
/// composition root and injected) drops each value on a utility-QoS serial queue, as Chrome hands
/// big objects to `base::SequencedTaskRunner::DeleteSoon` (`base/task/sequenced_task_runner.h`).
/// A slice on the main thread only unlinks: freeing a decoded image or an IOSurface can take
/// longer than the slice's whole budget.
///
/// ```swift
/// while bytes > cap {
///     if slice.isExpired { return .more }
///     sink.drop(evictOldest())  // the CGImage, Data or IOSurface the cache held
/// }
/// ```
public protocol MemoryReleaseSinking: Sendable {
    /// Takes `value` and drops it later on the sink's queue.
    ///
    /// The sink owns `value` from the call on, so the caller keeps no reference that could end on
    /// main after the queue's. Pass the last reference: a copy kept elsewhere makes that holder the
    /// one that frees it.
    /// Never pass a view or an object whose deinit needs the main thread.
    ///
    /// - Parameter value: What the consumer unlinked.
    func drop<Value>(_ value: consuming sending Value)
}
