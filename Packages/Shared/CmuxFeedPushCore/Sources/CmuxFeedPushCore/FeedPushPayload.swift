import Foundation

/// The parts of a feed push the app reads: `cmux.feed_item`, `kind`, `type`,
/// `scopes`, `subject`, `expires_at` and `aps.category`. Mail pushes carry no
/// content (only the item id).
public struct FeedPushPayload: Hashable, Sendable {
    public var item: String
    public var kind: String?
    public var type: String?
    public var category: FeedPushCategory?
    /// The scopes an approve request offers (`once`, `session`, `always`).
    public var scopes: [String]
    /// A review's subject (`plan`, `diff`, ...).
    public var subject: String?
    /// When the item stops mattering (owner clock, unix ms).
    public var expiresAt: Date?

    public init(item: String, kind: String? = nil, type: String? = nil, category: FeedPushCategory? = nil,
                scopes: [String] = [], subject: String? = nil, expiresAt: Date? = nil) {
        self.item = item
        self.kind = kind
        self.type = type
        self.category = category
        self.scopes = scopes
        self.subject = subject
        self.expiresAt = expiresAt
    }

    /// Owner item ids: a lowercase prefix, "_", then letters and digits (at most 80 characters).
    public static func isItemID(_ value: String) -> Bool {
        guard value.utf8.count <= 80, let underscore = value.firstIndex(of: "_") else { return false }
        let prefix = value[..<underscore]
        let rest = value[value.index(after: underscore)...]
        return !prefix.isEmpty && prefix.allSatisfy({ $0.isASCII && $0.isLowercase })
            && !rest.isEmpty && rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// Parses a notification's `userInfo`. Nil when it is not a feed push.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let item = cmux["feed_item"] as? String, Self.isItemID(item) else { return nil }
        self.item = item
        kind = cmux["kind"] as? String
        type = cmux["type"] as? String
        scopes = ((cmux["scopes"] as? [Any]) ?? []).compactMap { $0 as? String }
        subject = cmux["subject"] as? String
        expiresAt = (cmux["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let aps = userInfo["aps"] as? [String: Any]
        category = (aps?["category"] as? String).flatMap(FeedPushCategory.init(rawValue:))
    }

    /// The category the banner should use: the owner's when it named a known
    /// one, else derived from the kind.
    public var resolvedCategory: FeedPushCategory? {
        category ?? FeedPushCategory(feedKind: kind, type: type, scopes: scopes, subject: subject)
    }
}
