public import CmuxHomeCore
public import Foundation

/// Which conversations are pinned (the Home sidebar's grid). Client side,
/// per account, until the daemon's cloud proxy forwards `inbox.pin`
/// (home-cloud-proxy.md 8; the local owner refuses pins too): `pinned` is
/// the user's order; Chiefs and owner-pinned conversations are pinned by
/// default unless the user unpinned them (`unpinned`).
public struct HomePins: Hashable, Sendable, Codable {
    public var pinned: [ConversationID]
    public var unpinned: Set<ConversationID>

    public init(pinned: [ConversationID] = [], unpinned: Set<ConversationID> = []) {
        self.pinned = pinned
        self.unpinned = unpinned
    }

    public func isPinned(_ row: InboxRow) -> Bool {
        if pinned.contains(row.id) { return true }
        if unpinned.contains(row.id) { return false }
        return row.kind == .chief || row.isPinned
    }

    /// Pins `row` (at the end of the user's order) or unpins it.
    public mutating func setPinned(_ on: Bool, _ row: InboxRow) {
        pinned.removeAll { $0 == row.id }
        unpinned.remove(row.id)
        if on { pinned.append(row.id) } else if row.kind == .chief || row.isPinned { unpinned.insert(row.id) }
    }
}

/// One avatar circle: initials over a muted gradient picked from a stable seed.
public struct HomeAvatar: Hashable, Sendable {
    public var initials: String
    /// Stable per person (the participant id), for the gradient.
    public var seed: String
}

/// One conversation as the Home sidebar shows it, independent of the view
/// that draws it (the vendored MessagesLab sidebar maps from this).
public struct HomeSidebarItem: Hashable, Sendable, Identifiable {
    public var id: ConversationID
    public var title: String
    /// One avatar for a DM or a Chief; up to three members for a group.
    public var avatars: [HomeAvatar]
    public var isGroup: Bool
    /// A group's initials badge (the first member's initials), nil otherwise.
    public var badge: String?
    public var preview: String
    /// The newest message is a reply (the row shows a reply arrow).
    public var isReply: Bool
    /// "1:46 PM", "Yesterday", "Tuesday", "10/1/26".
    public var time: String
    public var unread: Bool
    public var unreadCount: Int
    public var mentions: Int
    public var isPinned: Bool
    public var isChief: Bool
    /// What VoiceOver reads.
    public var accessibilityLabel: String
}

/// The Home sidebar's content from the merged inbox (`HomeStore.rows`):
/// the pinned grid (Chiefs pinned by default), then every other
/// conversation newest first; a search filters both and lists matching
/// people the user has no DM with yet.
public struct HomeSidebarModel: Hashable, Sendable {
    public var pinned: [HomeSidebarItem]
    public var rows: [HomeSidebarItem]
    public var people: [HomeContact]

    public init(rows: [InboxRow], pins: HomePins, me: ParticipantID?, query: String = "", contacts: [HomeContact] = [],
                now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        pinned = []
        self.rows = []
        people = []
    }
}
