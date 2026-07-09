#if canImport(AppKit)

/// The text drawn over the menu-bar status icon for a given unread count.
///
/// `text` is `nil` when no badge should be drawn (zero unread). Counts above
/// nine collapse to `"9+"`; one through nine render as their decimal digit.
/// The menu-bar icon renderer reads ``text`` to decide whether and what to draw.
public struct MenuBarBadgeLabel: Equatable, Sendable {
    /// The badge text, or `nil` when no badge should be drawn.
    public let text: String?

    /// Derives the badge label for an unread count.
    public init(unreadCount: Int) {
        guard unreadCount > 0 else {
            text = nil
            return
        }
        text = unreadCount > 9 ? "9+" : String(unreadCount)
    }
}

#endif
