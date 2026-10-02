import Foundation

/// What the model hears from a feed owner: the connection, the mirror
/// bootstrap, one event per committed op, and the settle line of each of
/// this client's intents (after every event of its commit).
public nonisolated enum FeedSourceEvent: Sendable {
    case connection(FeedConnection)
    case snapshot(FeedSnapshot)
    case event(FeedEvent)
    case settled(key: String, reject: FeedReject?)
}

/// Where the model gets owner data. The App supplies sources for the
/// `FeedDO` stream and the local owner; demos and tests use `MockFeedSource`.
@MainActor
public protocol FeedSource: AnyObject {
    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void)
    /// Sends one intent with its idempotency key (`intent.key`). A resend
    /// after a reconnect uses the same key.
    func send(_ intent: FeedIntent)
    func stop()
}
