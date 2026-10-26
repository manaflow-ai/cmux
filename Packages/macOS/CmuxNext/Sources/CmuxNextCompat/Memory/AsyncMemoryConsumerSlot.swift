/// Where an ``AsyncMemoryConsumer`` that is not on the main actor (an actor) keeps its own
/// ``AsyncMemoryConsumerRegistration``, which lives on the main actor.
///
/// Chrome's consumer owns its `AsyncMemoryConsumerRegistration` as a member
/// (`base/memory_coordinator/async_memory_consumer_registration.h`). An actor cannot hold a
/// main-actor value in its isolated state, so it holds this slot as a `nonisolated let` and fills it
/// from the main actor. The slot keeps the registration as long as the actor keeps the slot; the
/// registration holds the consumer weakly, so there is no cycle.
///
/// ```swift
/// actor ThumbnailCache: AsyncMemoryConsumer {
///     private nonisolated let memorySlot = AsyncMemoryConsumerSlot()
///
///     @MainActor func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
///         memorySlot.register(name: "file-grid-thumbnails", traits: traits, consumer: self, registry: registry)
///     }
/// }
/// ```
@MainActor
public final class AsyncMemoryConsumerSlot {
    /// The registration this slot keeps, nil before ``register(name:traits:consumer:registry:hop:)``.
    public private(set) var registration: AsyncMemoryConsumerRegistration?

    /// Makes an empty slot (from any isolation, so an actor's stored property can make it).
    public nonisolated init() {}

    /// Registers `consumer` with `registry` and keeps the registration, replacing (and so releasing)
    /// an earlier one.
    ///
    /// - Parameters:
    ///   - name: The consumer's name in the memory report.
    ///   - traits: What the consumer holds and what freeing it costs.
    ///   - consumer: The consumer; the registration holds it weakly.
    ///   - registry: The memory coordinator (injected).
    ///   - hop: How a delivery leaves the main actor (``AsyncMemoryConsumerHop/task`` in the app).
    public func register(
        name: String,
        traits: MemoryConsumerTraits,
        consumer: any AsyncMemoryConsumer,
        registry: any MemoryConsumerRegistry,
        hop: AsyncMemoryConsumerHop = .task
    ) {
        registration = AsyncMemoryConsumerRegistration(
            name: name, traits: traits, consumer: consumer, registry: registry, hop: hop)
    }
}
