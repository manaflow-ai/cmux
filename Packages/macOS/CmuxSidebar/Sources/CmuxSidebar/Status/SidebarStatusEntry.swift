public import Foundation

/// One keyed status row shown under a workspace in the sidebar
/// (e.g. an agent status line), as reported over the control socket.
public struct SidebarStatusEntry: Equatable, Sendable {
    /// Stable key identifying the row (last write per key wins).
    public let key: String
    /// The displayed status text.
    public let value: String
    /// Optional SF Symbol name shown before the text.
    public let icon: String?
    /// Optional hex color for the row.
    public let color: String?
    /// Optional URL the row opens when clicked.
    public let url: URL?
    /// Sort priority (higher sorts first).
    public let priority: Int
    /// How `value` is rendered.
    public let format: SidebarMetadataFormat
    /// When the entry was reported.
    public let timestamp: Date
    /// When the agent behind this entry last replied with visible text, if
    /// it has reported one. Independent of `timestamp`: status changes (a
    /// tool call, a background wait) do not move it, and it carries across
    /// status updates for the same agent session.
    public let lastReplyAt: Date?

    /// Creates a status row (defaults mirror the legacy initializer).
    public init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date(),
        lastReplyAt: Date? = nil
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
        self.lastReplyAt = lastReplyAt
    }

    /// Whether a reported reply time should replace `current`: a newer time
    /// does, an older or equal one does not (hooks can arrive late), and
    /// `nil` (a new session) clears any time that is set.
    public static func shouldReplaceLastReply(_ current: Date?, with new: Date?) -> Bool {
        guard let new else { return current != nil }
        guard let current else { return true }
        return new > current
    }

    /// A copy with `lastReplyAt` replaced; every other field is kept.
    public func withLastReplyAt(_ date: Date?) -> SidebarStatusEntry {
        SidebarStatusEntry(
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format,
            timestamp: timestamp,
            lastReplyAt: date
        )
    }
}
