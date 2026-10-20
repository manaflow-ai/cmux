import Foundation

/// A user-selectable projection over notification-feed snapshots.
public enum MobileNotificationFeedFilter: Equatable, Hashable, Sendable {
    /// Includes every retained notification.
    case all
    /// Includes only notifications that have not been read.
    case unread

    /// Applies this filter without mutating the authoritative feed.
    /// - Parameter items: The immutable source snapshots.
    /// - Returns: Items included by the filter, preserving their input order.
    public func apply(to items: [MobileNotificationFeedItem]) -> [MobileNotificationFeedItem] {
        switch self {
        case .all:
            return items
        case .unread:
            return items.filter { !$0.isRead }
        }
    }
}
