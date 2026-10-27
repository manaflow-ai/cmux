/// Keeps one ``AsyncMemoryConsumer`` in a ``MemoryConsumerRegistry`` until it is released or
/// cancelled, and posts the registry's main-actor calls to the consumer.
///
/// A port of Chrome's `base/memory_coordinator/async_memory_consumer_registration.h`: the registry
/// holds a main-thread consumer that forwards each call to the consumer's own sequence through a weak
/// pointer. Here the forwarding consumer posts one delivery through an ``AsyncMemoryConsumerHop``
/// (a utility-priority `Task` in the app) and returns; ``MemoryConsumer/releaseMemory(within:)``
/// returns ``MemoryReleaseProgress/done`` at once, because the consumer frees on its own executor and
/// the main slice is never spent on it. While a delivery is pending, later calls only update it: the
/// consumer gets the newest limit, an update before a release, one call at a time and in order.
///
/// The registration holds the consumer weakly and takes a strong reference only for the length of
/// one call. Cancelling or releasing it, on any thread, stops the registry's calls and drops every
/// pending call; a call a running delivery already took may still reach the consumer once, and its
/// result is not kept (Chrome cancels on the consumer's own sequence; here cancel runs on any
/// thread). When the consumer itself goes, its entry stops being live and leaves the report.
///
/// ```swift
/// thumbnailsRegistration = AsyncMemoryConsumerRegistration(
///     name: "file-grid-thumbnails", traits: traits, consumer: thumbnailCache, registry: memory)
/// ```
@MainActor
public final class AsyncMemoryConsumerRegistration {
    /// The forwarding consumer's entry in the registry.
    public let entry: MemoryConsumerEntry
    private let forwarder: AsyncMemoryConsumerForwarder
    private let link: AsyncMemoryConsumerLink

    /// Adds `consumer` to `registry` under `name`; the current limit is posted to `consumer` before
    /// this returns.
    ///
    /// - Parameters:
    ///   - name: The consumer's name in the memory report (stable, kebab-case).
    ///   - traits: What the consumer holds and what freeing it costs.
    ///   - consumer: The consumer; the registration holds it weakly.
    ///   - registry: The memory coordinator (injected); the registration does not keep it.
    ///   - hop: How a delivery leaves the main actor (``AsyncMemoryConsumerHop/task`` in the app).
    public init(
        name: String,
        traits: MemoryConsumerTraits,
        consumer: any AsyncMemoryConsumer,
        registry: any MemoryConsumerRegistry,
        hop: AsyncMemoryConsumerHop = .task
    ) {
        let link = AsyncMemoryConsumerLink(consumer: consumer, hop: hop)
        let forwarder = AsyncMemoryConsumerForwarder(link: link)
        self.link = link
        self.forwarder = forwarder
        entry = MemoryConsumerEntry(
            name: name, traits: traits, consumer: forwarder, reachable: { link.isConsumerAlive })
        registry.addMemoryConsumer(entry)
    }

    /// Stops the registry's calls and drops pending deliveries now (also happens when the
    /// registration is released).
    public func cancel() {
        entry.markReleased()
        link.cancel()
    }

    deinit {
        entry.markReleased()
        link.cancel()
    }
}

/// How an ``AsyncMemoryConsumerRegistration`` sends a delivery off the main actor: the one enqueue
/// the main actor pays per call. Injected so a test decides when a delivery runs.
public struct AsyncMemoryConsumerHop: Sendable {
    private let post: @Sendable (_ delivery: @escaping @Sendable () async -> Void) -> Void

    /// Makes a hop that hands each delivery to `post`.
    ///
    /// - Parameter post: Runs `delivery` later, off the main actor; called on the main actor.
    public init(_ post: @escaping @Sendable (_ delivery: @escaping @Sendable () async -> Void) -> Void) {
        self.post = post
    }

    /// One utility-priority `Task` per delivery; the consumer's own calls then run on its executor.
    public static let task = AsyncMemoryConsumerHop { delivery in
        Task(priority: .utility) { @concurrent in await delivery() }
    }

    /// Sends `delivery` off the main actor.
    ///
    /// - Parameter delivery: The calls to make on the consumer.
    public func callAsFunction(_ delivery: @escaping @Sendable () async -> Void) {
        post(delivery)
    }
}
