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
    /// Muted (the person's Cloud mute): the row draws dimmed.
    public var isMuted = false

    /// Unread messages, or the user's Mark as Unread (then the count is at least one).
    public var unread: Bool
    public var unreadCount: Int
    public var mentions: Int
    public var isPinned: Bool
    public var isChief: Bool
    /// A Chief's own avatar (`HomeSidebarModel.init`'s `chiefAvatar`); nil
    /// draws the participant's initials.
    public var chiefAvatar: HomeChiefAvatar?
    /// A Chief that runs on another engine than the default: that engine's name
    /// ("UniiChat", "Codex"; ``ChiefBackend/badge(for:)``); nil otherwise.
    public var backendBadge: String?
    /// What VoiceOver reads.
    public var accessibilityLabel: String
}

/// The Home sidebar's content from the merged inbox (`HomeStore.rows`):
/// the pinned grid, then every other conversation newest first; a search
/// filters both and lists matching people the user has no DM with yet. In
/// the owner's order (`init(ordered:)`, its `home-inbox` rows) only the
/// person's own pins are pinned; with this Mac's pins Chiefs are pinned by default.
public struct HomeSidebarModel: Hashable, Sendable {
    public var pinned: [HomeSidebarItem]
    public var rows: [HomeSidebarItem]
    public var people: [HomeContact]
    /// The Cloud rows' state from the owner (`home-inbox` `cloud`): only `unavailable` shows a quiet line.
    public var cloudState: String?
    /// The quiet line under the list (Cloud conversations not reachable), or nil.
    public var note: String? { HomeConversationStrings.cloudNote(cloudState) }

    /// `unreadMarks`: conversations the user marked unread (Mark as Unread), shown unread until read.
    /// `chiefHarnesses`: each Chief's engine by participant id, for the rows' badges.
    public init(rows: [InboxRow], pins: HomePins, me: ParticipantID?, query: String = "", contacts: [HomeContact] = [],
                unreadMarks: Set<ConversationID> = [], chiefAvatar: HomeChiefAvatar? = nil, chiefHarnesses: [String: String] = [:],
                now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        let (pinnedRows, rest) = pins.split(rows)
        self.init(pinned: pinnedRows, rest: rest, all: rows, me: me, query: query, contacts: contacts, unreadMarks: unreadMarks,
                  chiefAvatar: chiefAvatar, chiefHarnesses: chiefHarnesses, now: now, calendar: calendar, locale: locale)
    }

    /// The list in an order made elsewhere (the owner's `home-inbox` rows): `rows` in list order, the
    /// pinned grid is the rows in `pinned` in that order, the other rows follow in that order.
    public init(ordered rows: [InboxRow], pinned: Set<ConversationID>, me: ParticipantID?, query: String = "",
                contacts: [HomeContact] = [], unreadMarks: Set<ConversationID> = [], chiefAvatar: HomeChiefAvatar? = nil,
                chiefHarnesses: [String: String] = [:], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.init(pinned: rows.filter { pinned.contains($0.id) }, rest: rows.filter { !pinned.contains($0.id) }, all: rows, me: me,
                  query: query, contacts: contacts, unreadMarks: unreadMarks, chiefAvatar: chiefAvatar, chiefHarnesses: chiefHarnesses,
                  now: now, calendar: calendar, locale: locale)
    }

    private init(pinned pinnedRows: [InboxRow], rest: [InboxRow], all rows: [InboxRow], me: ParticipantID?, query: String,
                 contacts: [HomeContact], unreadMarks: Set<ConversationID>, chiefAvatar: HomeChiefAvatar?,
                 chiefHarnesses: [String: String], now: Date, calendar: Calendar, locale: Locale) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = { (row: InboxRow) in needle.isEmpty || row.matches(needle, me: me) }
        let pinnedRows = pinnedRows.filter(match), rest = rest.filter(match)
        let item = { (row: InboxRow, pinned: Bool) in
            var item = HomeSidebarItem(row: row, pinned: pinned, markedUnread: unreadMarks.contains(row.id), me: me, now: now,
                                       calendar: calendar, locale: locale)
            if item.isChief {
                item.chiefAvatar = chiefAvatar
                let chief = row.summary.participants.first(where: \.isChief)?.id.rawValue
                item.backendBadge = ChiefBackend.badge(for: chief.flatMap { chiefHarnesses[$0] })
            }
            item.isMuted = row.summary.muted
            return item
        }
        pinned = needle.isEmpty ? pinnedRows.map { item($0, true) } : []
        self.rows = needle.isEmpty ? rest.map { item($0, false) } : pinnedRows.map { item($0, true) } + rest.map { item($0, false) }
        guard !needle.isEmpty else { people = []; return }
        // People the user has no DM with yet, by name.
        let dmPeers = Set(rows.filter { $0.kind == .direct }.flatMap { $0.summary.participants.map(\.id) })
        people = contacts.filter { !dmPeers.contains($0.id) && $0.name.localizedStandardContains(needle) }
    }
}

extension HomeSidebarItem {
    init(row: InboxRow, pinned: Bool, markedUnread: Bool = false, me: ParticipantID?, now: Date, calendar: Calendar,
         locale: Locale) {
        let others = row.summary.participants.filter { $0.id != me }
        // The sender's DM with someone not on it yet says who it waits for (DESIGN 2.5).
        let waiting = row.kind == .direct ? row.summary.homeInviteWaiting(me: me) : nil
        let preview = waiting.map { HomeRowPreview(text: $0, isReply: false) } ?? row.homePreview(me: me)
        let time = row.timestamp.homeListTime(now: now, calendar: calendar, locale: locale)
        let title = row.title.isEmpty ? HomeConversationStrings.untitled : row.title
        let unread = max(row.unread, markedUnread ? 1 : 0)
        self.init(
            id: row.id, title: title,
            avatars: others.prefix(row.kind == .group ? 3 : 1).map { HomeAvatar(initials: $0.initials, seed: $0.id.rawValue) },
            isGroup: row.kind == .group, badge: row.kind == .group ? others.first?.initials : nil,
            preview: preview.text, isReply: preview.isReply, time: time, lastAt: row.timestamp,
            people: others.map { HomeSidebarPerson(id: $0.id.rawValue, name: $0.displayName, initials: $0.initials) }, unread: unread > 0, unreadCount: unread,
            mentions: row.mentions, isPinned: pinned, isChief: row.kind == .chief, chiefAvatar: nil, backendBadge: nil,
            accessibilityLabel: Self.accessibility(title: title, row: row, unread: unread, preview: preview.text, time: time))
    }

    /// The title, unread and mention state, the time, then the preview.
    static func accessibility(title: String, row: InboxRow, unread: Int, preview: String, time: String) -> String {
        var parts = [title]
        if unread > 0 { parts.append(HomeConversationStrings.unread(unread)) }
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
