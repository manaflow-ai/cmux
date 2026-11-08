import Foundation

/// The mobile feed's coarse loading and availability state.
public enum MobileNotificationFeedStatus: Equatable, Sendable {
    /// No refresh has been attempted yet.
    case idle
    /// At least one capable Mac is currently being read.
    case loading
    /// The current or last-known feed is available for presentation.
    case ready
    /// No capable Mac can currently provide the feed.
    case unavailable
    /// Connected Macs are too old to advertise `notification.feed.v1`.
    case requiresMacUpdate
}
