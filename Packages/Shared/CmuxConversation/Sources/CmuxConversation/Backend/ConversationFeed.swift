/// One open conversation's event stream: its newest history first, then
/// live events, with older history on request.
///
/// The feed owns the backend-specific cursor and recovers on its own: after
/// a dropped link or a reported gap it replays what was missed from where it
/// stopped, so its consumer only ever folds ``FeedUpdate/events(_:hasOlder:)``.
public protocol ConversationFeed: Sendable {
    /// Updates, in order, until ``close()``.
    var updates: AsyncStream<FeedUpdate> { get }
    /// Loads the page of history before the oldest loaded event; it arrives
    /// as ``FeedUpdate/events(_:hasOlder:)``.
    /// - Parameter pageSize: The most events to load.
    /// - Throws: When the backend cannot be reached.
    func loadOlder(pageSize: Int) async throws
    /// Stops the feed and releases the backend subscription.
    func close() async
}
