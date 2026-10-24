/// The store's unread counts: what the Dock badge, the notification center and the sidebar's
/// notification row show (``DaemonStore/unreadTotals``).
///
/// ```swift
/// let badge = store.unreadTotals.badge(homeUnread: home.unreadConversations.map(\.rawValue))
/// ```
public struct UnreadTotals: Sendable, Equatable {
    /// Each workspace's unread tabs, or 1 for a workspace with none that the person marked unread
    /// (a mark adds nothing to a workspace that already has unread tabs).
    public var tabs = 0
    /// The conversation ids of unread conversation tabs, with the number of tabs that show each.
    public var conversations: [String: Int] = [:]

    /// - Parameters:
    ///   - tabs: The workspaces' unread count.
    ///   - conversations: Unread conversation tabs by conversation id.
    public init(tabs: Int = 0, conversations: [String: Int] = [:]) {
        self.tabs = tabs
        self.conversations = conversations
    }

    /// The Dock badge: ``tabs``, plus one for each of Home's unread conversations (`homeUnread`,
    /// conversation ids) that no workspace tab already counts with its own unread marker.
    /// - Parameter homeUnread: Home's unread conversation ids.
    /// - Returns: The count to show.
    public func badge(homeUnread: [String]) -> Int {
        guard !homeUnread.isEmpty else { return tabs }
        return tabs + Set(homeUnread).filter { conversations[$0] == nil }.count
    }

    mutating func add(_ other: UnreadTotals) {
        tabs += other.tabs
        for (id, count) in other.conversations { conversations[id, default: 0] += count }
    }
}
