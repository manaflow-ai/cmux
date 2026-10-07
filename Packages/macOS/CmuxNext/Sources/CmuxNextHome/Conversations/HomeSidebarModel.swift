public import CmuxHomeCore
public import Foundation

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
    /// The newest message's time (MessagesLab's sidebar formats its own label).
    public var lastAt: Date
    /// The other participants in display order.
    public var people: [HomeSidebarPerson]

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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = needle.isEmpty ? rows : rows.filter { $0.matches(needle, me: me) }
        let order = Dictionary(pins.pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // User pins in their order, then default pins (Chiefs, owner pins) in inbox order.
        let pinnedRows = shown.filter { pins.isPinned($0) }.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
        let rest = shown.filter { !pins.isPinned($0) }.sorted { a, b in
            a.timestamp != b.timestamp ? a.timestamp > b.timestamp : a.id.rawValue < b.id.rawValue
        }
        let item = { (row: InboxRow, pinned: Bool) in
            HomeSidebarItem(row: row, pinned: pinned, me: me, now: now, calendar: calendar, locale: locale)
        }
        pinned = needle.isEmpty ? pinnedRows.map { item($0, true) } : []
        self.rows = (needle.isEmpty ? rest : pinnedRows + rest).map { item($0, pins.isPinned($0)) }
        guard !needle.isEmpty else { people = []; return }
        // People the user has no DM with yet, by name.
        let dmPeers = Set(rows.filter { $0.kind == .direct }.flatMap { $0.summary.participants.map(\.id) })
        people = contacts.filter { !dmPeers.contains($0.id) && $0.name.localizedStandardContains(needle) }
    }
}

extension HomeSidebarItem {
    init(row: InboxRow, pinned: Bool, me: ParticipantID?, now: Date, calendar: Calendar, locale: Locale) {
        let others = row.summary.participants.filter { $0.id != me }
        let preview = row.homePreview(me: me)
        let time = row.timestamp.homeListTime(now: now, calendar: calendar, locale: locale)
        let title = row.title.isEmpty ? HomeConversationStrings.untitled : row.title
        self.init(
            id: row.id, title: title,
            avatars: others.prefix(row.kind == .group ? 3 : 1).map { HomeAvatar(initials: $0.initials, seed: $0.id.rawValue) },
            isGroup: row.kind == .group, badge: row.kind == .group ? others.first?.initials : nil,
            preview: preview.text, isReply: preview.isReply, time: time, lastAt: row.timestamp,
            people: others.map { HomeSidebarPerson(id: $0.id.rawValue, name: $0.displayName, initials: $0.initials) }, unread: row.unread > 0, unreadCount: row.unread,
            mentions: row.mentions, isPinned: pinned, isChief: row.kind == .chief,
            accessibilityLabel: Self.accessibility(title: title, row: row, preview: preview.text, time: time))
    }

    /// The title, unread and mention state, the time, then the preview.
    static func accessibility(title: String, row: InboxRow, preview: String, time: String) -> String {
        var parts = [title]
        if row.unread > 0 { parts.append(HomeConversationStrings.unread(row.unread)) }
        if row.mentions > 0 { parts.append(HomeConversationStrings.mentioned) }
        if !time.isEmpty { parts.append(time) }
        if !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }
}

extension InboxRow {
    /// A search match: the title, a member's name or the preview.
    func matches(_ needle: String, me: ParticipantID?) -> Bool {
        title.localizedStandardContains(needle) || preview.localizedStandardContains(needle)
            || summary.participants.contains { $0.id != me && $0.displayName.localizedStandardContains(needle) }
    }
}

extension HomeSidebarModel {
    /// The conversation `offset` places after `current` in the list's visual
    /// order (the pinned grid, then the rows); nil past either end (Messages
    /// stops there). With nothing shown, or one no longer listed, the first.
    public func neighbor(of current: ConversationID?, offset: Int) -> ConversationID? {
        let order = (pinned + rows).map(\.id)
        guard let current, let index = order.firstIndex(of: current) else { return order.first }
        let next = index + offset
        return order.indices.contains(next) ? order[next] : nil
    }
}
