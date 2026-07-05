public import Foundation

/// A normalized message, event, or actionable inbox item.
public struct InboxItem: Codable, Equatable, Identifiable, Sendable {
    /// Local stable item id.
    public let itemID: String
    /// Local thread id.
    public let threadID: String
    /// Source service for this item.
    public let source: InboxSource
    /// Source-specific account id.
    public let accountID: String
    /// Source message id used for dedupe.
    public let externalMessageID: String
    /// Sender or actor display name.
    public var sender: InboxParticipant
    /// Source timestamp.
    public var timestamp: Date
    /// Short preview safe to show in rows and notifications.
    public var bodyPreview: String
    /// Optional full local body for context and search.
    public var body: String?
    /// Source-specific non-secret metadata.
    public var metadata: [String: String]
    /// Whether this item is unread.
    public var isUnread: Bool
    /// Whether this item needs user action.
    public var isActionable: Bool
    /// Optional associated draft id.
    public var draftID: String?
    /// Optional source deep link.
    public var externalURL: String?

    /// Stable identity used by SwiftUI lists.
    public var id: String { itemID }

    /// Creates a normalized inbox item.
    public init(
        itemID: String,
        threadID: String,
        source: InboxSource,
        accountID: String,
        externalMessageID: String,
        sender: InboxParticipant,
        timestamp: Date,
        bodyPreview: String,
        body: String? = nil,
        metadata: [String: String] = [:],
        isUnread: Bool = true,
        isActionable: Bool = false,
        draftID: String? = nil,
        externalURL: String? = nil
    ) {
        self.itemID = itemID
        self.threadID = threadID
        self.source = source
        self.accountID = accountID
        self.externalMessageID = externalMessageID
        self.sender = sender
        self.timestamp = timestamp
        self.bodyPreview = bodyPreview
        self.body = body
        self.metadata = metadata
        self.isUnread = isUnread
        self.isActionable = isActionable
        self.draftID = draftID
        self.externalURL = externalURL
    }
}
