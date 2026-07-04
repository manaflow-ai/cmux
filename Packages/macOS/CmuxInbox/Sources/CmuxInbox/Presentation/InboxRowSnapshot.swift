public import Foundation

/// Immutable row snapshot for Inbox list rendering.
public struct InboxRowSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// Local item id.
    public let itemID: String
    /// Local thread id.
    public let threadID: String
    /// Source service.
    public let source: InboxSource
    /// Source symbol.
    public let symbolName: String
    /// Sender or actor label.
    public let sender: String
    /// Thread display title.
    public let title: String
    /// Preview text.
    public let preview: String
    /// Timestamp for sorting and age display.
    public let timestamp: Date
    /// Whether the row is unread.
    public let isUnread: Bool
    /// Whether the row needs user action.
    public let isActionable: Bool
    /// Optional deep link.
    public let externalURL: String?

    /// Stable identity.
    public var id: String { itemID }

    /// Creates a row snapshot.
    public init(item: InboxItem, thread: InboxThread?) {
        itemID = item.itemID
        threadID = item.threadID
        source = item.source
        symbolName = InboxPresentationModel.symbolName(for: item.source)
        sender = item.sender.displayName
        title = thread?.title ?? item.sender.displayName
        preview = item.bodyPreview
        timestamp = item.timestamp
        isUnread = item.isUnread
        isActionable = item.isActionable
        externalURL = item.externalURL ?? thread?.externalURL
    }
}
