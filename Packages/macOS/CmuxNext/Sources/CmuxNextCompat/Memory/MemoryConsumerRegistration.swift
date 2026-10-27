/// Keeps one ``MemoryConsumer`` in a ``MemoryConsumerRegistry`` until it is released or cancelled
/// (RAII, as Chrome's `base/memory_coordinator/memory_consumer_registration.h`).
///
/// The init adds the consumer and the registry hands it the current limit before the init returns.
/// Keep the registration in a stored property of the consumer's owner. Cancelling or releasing it,
/// on any thread, marks its entry released with one atomic store: the registry never calls the
/// consumer again and drops the entry on its next add or walk.
///
/// ```swift
/// registration = MemoryConsumerRegistration(
///     name: "preview-images", traits: traits, consumer: self, registry: registry)
/// ```
@MainActor
public final class MemoryConsumerRegistration {
    /// The consumer's entry in the registry.
    public let entry: MemoryConsumerEntry

    /// Adds `consumer` to `registry` under `name`; `consumer` gets the current limit before this
    /// returns.
    ///
    /// - Parameters:
    ///   - name: The consumer's name in the memory report (stable, kebab-case).
    ///   - traits: What the consumer holds and what freeing it costs.
    ///   - consumer: The consumer; the registry holds it weakly.
    ///   - registry: The memory coordinator (injected); the registration does not keep it.
    public init(
        name: String,
        traits: MemoryConsumerTraits,
        consumer: any MemoryConsumer,
        registry: any MemoryConsumerRegistry
    ) {
        entry = MemoryConsumerEntry(name: name, traits: traits, consumer: consumer)
        registry.addMemoryConsumer(entry)
    }

    /// Stops the registry's calls now (also happens when the registration is released).
    public func cancel() {
        entry.markReleased()
    }

    deinit {
        entry.markReleased()
    }
}
