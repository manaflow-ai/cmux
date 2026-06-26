/// The dock-tile badge text for the current unread + run-tag state.
///
/// Pure formatter. The badge shows the unread count (capped at `"99+"`) only when
/// dock badging is enabled and the count is positive; a normalized run tag, when
/// present, prefixes the count (`"tag:7"`) or stands alone (`"tag"`) so tagged dev
/// builds stay distinguishable even with no unread notifications. ``text`` is `nil`
/// when there is nothing to show.
public struct DockBadgeLabel: Sendable, Equatable {
    /// Total unread notification count.
    public let unreadCount: Int
    /// Whether dock badging is enabled in settings.
    public let isEnabled: Bool
    /// Raw run tag to normalize and display, if any.
    public let runTag: String?

    /// Creates a badge descriptor for the given unread/run-tag state.
    public init(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) {
        self.unreadCount = unreadCount
        self.isEnabled = isEnabled
        self.runTag = runTag
    }

    /// The badge string to set on the dock tile, or `nil` when nothing should show.
    public var text: String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let badge = TaggedRunBadge(runTag) {
            if let unreadLabel {
                return "\(badge.tag):\(unreadLabel)"
            }
            return badge.tag
        }

        return unreadLabel
    }
}
