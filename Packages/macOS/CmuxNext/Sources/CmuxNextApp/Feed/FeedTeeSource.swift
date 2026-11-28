import CmuxNextFeed

/// Forwards a feed source to the model and lets `FeedService` see the owner's
/// own events (connection, snapshot, committed items), never the model's
/// overlay of pending intents. Request waiters resolve only on owner truth.
@MainActor
final class FeedTeeSource: FeedSource {
    private let inner: any FeedSource
    private let observe: @MainActor (FeedSourceEvent) -> Void

    init(_ inner: any FeedSource, observe: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.inner = inner
        self.observe = observe
    }

    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        let observe = observe
        inner.start { event in
            observe(event)
            sink(event)
        }
    }

    func send(_ intent: FeedIntent) { inner.send(intent) }
    func stop() { inner.stop() }
}
