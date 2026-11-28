import Foundation

public nonisolated enum FeedConnection: Sendable, Equatable {
    case connecting
    case connected
    /// The owner is unreachable: the panel shows it and refuses changes
    /// (nothing queues offline, user decision 2026-10-01).
    case disconnected(String)
}

/// The owner refused an intent (feed.md section 6 errors).
public nonisolated enum FeedReject: Error, Sendable, Equatable {
    /// `feed.closed`: the request closed first (answered on another device,
    /// cancelled, expired). Carries the item so the client can show
    /// "Answered on iPhone".
    case closed(FeedItem)
    /// `feed.moving`: the item is being handed to the cloud owner; retryable.
    case moving
    /// The answer does not match the kind's schema.
    case invalid(String)
    /// The client refused locally: the owner is unreachable.
    case disconnected
    case other(String)

    /// The closed item, for `closed`.
    public var closedItem: FeedItem? {
        if case let .closed(item) = self { return item }
        return nil
    }
}
