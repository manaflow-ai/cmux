/// One registered ``MemoryConsumer`` as the registry keeps it: its name, its traits and a weak
/// reference to it.
///
/// ``MemoryConsumerRegistration`` makes it and hands it to the ``MemoryConsumerRegistry``. The
/// registry holds the consumer weakly, so an owner that is its own consumer and keeps its
/// registration in a stored property makes no cycle. A registration cancelled or released, on any
/// thread, marks its entry released at once (one atomic store); the registry skips it from then on
/// and drops it on its next add or walk.
@MainActor
public final class MemoryConsumerEntry {
    /// The consumer's name in the memory report and `debug.memory` (Chrome's consumer ID).
    public let name: String
    /// What the consumer holds and what freeing it costs.
    public let traits: MemoryConsumerTraits
    /// The consumer, while it exists.
    public private(set) weak var consumer: (any MemoryConsumer)?

    nonisolated private let released = Atomic<Bool>(false)

    init(name: String, traits: MemoryConsumerTraits, consumer: any MemoryConsumer) {
        self.name = name
        self.traits = traits
        self.consumer = consumer
    }

    /// The consumer, unless its registration was released or it no longer exists. The registry
    /// calls only this one.
    public var liveConsumer: (any MemoryConsumer)? {
        released.load(ordering: .acquiring) ? nil : consumer
    }

    /// Whether the registry should still call this consumer.
    public var isLive: Bool {
        liveConsumer != nil
    }

    /// Marks the entry released (any thread; a second call does nothing).
    nonisolated func markReleased() {
        released.store(true, ordering: .releasing)
    }
}
