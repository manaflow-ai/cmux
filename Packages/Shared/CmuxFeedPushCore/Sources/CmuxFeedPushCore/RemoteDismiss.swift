import Foundation

/// A background push from the feed owner: these items no longer need the
/// user (answered or read elsewhere), and the badge is now `badge`.
/// Delivered banners use the item id as their identifier (`apns-collapse-id`).
public struct RemoteDismiss: Hashable, Sendable {
    public var items: [String]
    public var badge: Int?

    public init(items: [String], badge: Int?) {
        self.items = items
        self.badge = badge
    }

    /// Nil when the push carries neither a valid dismiss list nor a badge.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any] else { return nil }
        let ids = ((cmux["dismiss"] as? [Any]) ?? []).compactMap { $0 as? String }.filter(FeedPushPayload.isItemID)
        let badge = (cmux["badge"] as? NSNumber).map(\.intValue).map { max(0, $0) }
        guard !ids.isEmpty || badge != nil else { return nil }
        items = Array(ids.prefix(256))
        self.badge = badge
    }
}
