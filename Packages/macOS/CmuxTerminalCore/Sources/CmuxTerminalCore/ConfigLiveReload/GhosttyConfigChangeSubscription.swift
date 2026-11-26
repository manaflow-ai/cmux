/// A live subscription to filesystem changes for a set of config paths,
/// returned by ``GhosttyConfigChangeSource/subscribe(toPaths:)``.
public struct GhosttyConfigChangeSubscription: Sendable {
    /// Yields once per change notification. Changes are invalidations, not
    /// quantities, so a slow consumer may see several changes as one element.
    public let events: AsyncStream<Void>

    private let tearDown: @Sendable () async -> Void

    /// Creates a subscription.
    ///
    /// - Parameters:
    ///   - events: The change stream.
    ///   - tearDown: Stops the underlying watchers and finishes `events`.
    public init(
        events: AsyncStream<Void>,
        tearDown: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.tearDown = tearDown
    }

    /// Stops watching and finishes ``events``. Idempotent.
    public func cancel() async {
        await tearDown()
    }
}
