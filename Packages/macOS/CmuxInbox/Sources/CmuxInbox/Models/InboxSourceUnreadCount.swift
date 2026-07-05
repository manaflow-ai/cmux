import Foundation

/// Unread count for a source, optionally scoped to one account.
public struct InboxSourceUnreadCount: Codable, Equatable, Identifiable, Sendable {
    /// Source service.
    public let source: InboxSource
    /// Optional source account id.
    public let accountID: String?
    /// Number of unread items.
    public let unreadCount: Int
    /// Number of actionable unread or pending items.
    public let actionableCount: Int

    /// Stable identity used by SwiftUI lists.
    public var id: String { "\(source.rawValue):\(accountID ?? "*")" }

    /// Creates a source count.
    public init(source: InboxSource, accountID: String? = nil, unreadCount: Int, actionableCount: Int) {
        self.source = source
        self.accountID = accountID
        self.unreadCount = unreadCount
        self.actionableCount = actionableCount
    }
}
