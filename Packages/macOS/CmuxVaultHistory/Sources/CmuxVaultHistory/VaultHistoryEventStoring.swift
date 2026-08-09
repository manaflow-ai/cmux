import Foundation

/// Persistence boundary consumed by the app-owned History coordinator.
public protocol VaultHistoryEventStoring: Sendable {
    /// Persists one event before making it visible to readers.
    ///
    /// - Parameter event: Immutable event to append.
    /// - Returns: `true` when the event was accepted and is now readable.
    func append(_ event: VaultHistoryEvent) async -> Bool

    /// Returns the newest persisted events in deterministic order.
    ///
    /// - Parameter limit: Maximum number of events returned.
    /// - Returns: Events ordered by timestamp and stable identifier, newest first.
    func recentEvents(limit: Int) async -> [VaultHistoryEvent]
}
