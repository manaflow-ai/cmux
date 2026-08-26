/// The unread indicator state one workspace row (or group header) renders,
/// mirroring the Mac sidebar badge: unread rows show the exact count when the
/// Mac reports one, and fall back to the plain dot against Macs old enough to
/// emit only the boolean.
public struct MobileWorkspaceUnreadState: Hashable, Sendable {
    /// Whether any unread activity exists (drives indicator visibility).
    public var isUnread: Bool
    /// The exact unread count, when known. `nil` means "unread, amount
    /// unknown" (old Mac), which renders as the count-less dot. Read rows
    /// always know their count is 0.
    public var count: Int?

    /// Creates an unread state.
    public init(isUnread: Bool, count: Int?) {
        self.isUnread = isUnread
        self.count = count
    }

    /// The all-read state.
    public static let read = MobileWorkspaceUnreadState(isUnread: false, count: 0)

    /// Folds another row's state into an aggregate (group headers sum their
    /// members, mirroring the Mac's collapsed-group badge). An unknown count
    /// from any unread contributor poisons the sum: a numeric badge must never
    /// undercount hidden activity, so the aggregate then falls back to the dot.
    public func merging(_ other: MobileWorkspaceUnreadState) -> MobileWorkspaceUnreadState {
        MobileWorkspaceUnreadState(
            isUnread: isUnread || other.isUnread,
            count: count.flatMap { mine in other.count.map { mine + $0 } }
        )
    }
}

extension MobileWorkspacePreview {
    /// The row's unread indicator state. A read row's count is authoritatively
    /// 0 even against a Mac that predates `unread_count`.
    public var unreadState: MobileWorkspaceUnreadState {
        MobileWorkspaceUnreadState(
            isUnread: hasUnread,
            count: unreadCount ?? (hasUnread ? nil : 0)
        )
    }
}
