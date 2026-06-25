/// Pure formatter for the macOS Dock badge string shown on the cmux icon.
///
/// The badge combines an optional normalized run tag with the unread-count
/// label. It is a value type holding its inputs and deriving the badge string,
/// so it is neither a namespace enum nor a static-only utility. Tag
/// normalization (length cap, trimming, env lookup) is a separate settings
/// concern and stays with its owner; this formatter receives the
/// already-normalized tag.
public struct DockBadgeLabel: Equatable, Sendable {
    /// The number of unread notifications.
    public let unreadCount: Int
    /// Whether the unread badge is enabled.
    public let isEnabled: Bool
    /// An already-normalized run tag, or `nil`.
    public let normalizedRunTag: String?

    /// Creates a Dock badge formatter for the given inputs.
    public init(unreadCount: Int, isEnabled: Bool, normalizedRunTag: String?) {
        self.unreadCount = unreadCount
        self.isEnabled = isEnabled
        self.normalizedRunTag = normalizedRunTag
    }

    /// The badge string, or `nil` when there is nothing to show.
    public var value: String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = normalizedRunTag {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }
}
