/// The parts of a feed push the app reads: `cmux.feed_item`, `kind`, `type`
/// and `aps.category`. Mail pushes carry no content (only the item id).
public struct FeedPushPayload: Hashable, Sendable {
    public var item: String
    public var kind: String?
    public var type: String?
    public var category: FeedPushCategory?

    public init(item: String, kind: String? = nil, type: String? = nil, category: FeedPushCategory? = nil) {
        self.item = item
        self.kind = kind
        self.type = type
        self.category = category
    }

    /// Parses a notification's `userInfo`. Nil when it is not a feed push.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let item = cmux["feed_item"] as? String, !item.isEmpty else { return nil }
        self.item = item
        kind = cmux["kind"] as? String
        type = cmux["type"] as? String
        let aps = userInfo["aps"] as? [String: Any]
        category = (aps?["category"] as? String).flatMap(FeedPushCategory.init(rawValue:))
    }
}
