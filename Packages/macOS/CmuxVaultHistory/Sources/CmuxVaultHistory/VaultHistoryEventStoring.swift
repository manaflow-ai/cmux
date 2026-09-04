import Foundation

/// Persistence boundary consumed by the app-owned History coordinator.
public protocol VaultHistoryEventStoring: Sendable {
    /// Processes one event through persistence and bounded retention.
    ///
    /// - Parameter event: Immutable event to append.
    /// - Returns: `true` when storage accepted the mutation. An event older
    ///   than the retained timestamp window can be evicted immediately.
    func append(_ event: VaultHistoryEvent) async -> Bool

    /// Returns the newest persisted events in deterministic order.
    ///
    /// - Parameter limit: Maximum number of events returned.
    /// - Returns: Events ordered by timestamp and stable identifier, newest first.
    func recentEvents(limit: Int) async -> [VaultHistoryEvent]
}
