public import CmuxHomeCore
public import Foundation

/// The Chiefs as New Message's list under To: shows them: the main Chief
/// first, and each row tagged where it runs as the Home list tags it
/// ("Chief · Main · Cloud", "Chief · This Mac"), so two Chiefs named alike tell apart.
extension HomeChiefRoster {
    /// `contacts` with the main Chief first (before a list's limit can cut it).
    /// - Parameters:
    ///   - contacts: New Message's contacts.
    ///   - rows: The inbox rows (the main Chief's conversation names its participant).
    /// - Returns: The same contacts, the main Chief moved to the front.
    public func mainFirst(_ contacts: [HomeContact], rows: [InboxRow]) -> [HomeContact] {
        guard let main, let row = rows.first(where: { $0.id == main }) else { return contacts }
        let isMain = { (contact: HomeContact) in row.summary.participants.contains { $0.id == contact.id } }
        return contacts.filter(isMain) + contacts.filter { !isMain($0) }
    }

    /// How New Message's list draws `recipient`: a Chief's avatar and its tag; others draw initials.
    /// - Parameters:
    ///   - recipient: The suggestion.
    ///   - rows: The inbox rows (a Chief's own conversation carries its tag).
    ///   - avatars: Each Chief's avatar by participant id.
    ///   - fallback: The avatar of a Chief with none of its own.
    ///   - harnesses: Each Chief's engine by participant id (a non-default one joins the tag).
    ///   - now: The time "Active 2 hours ago" counts from.
    /// - Returns: The row's avatar, tag and last activity (the list shows it only to tell alike Chiefs apart).
    public func look(_ recipient: HomeRecipient, rows: [InboxRow], avatars: [String: HomeChiefAvatar], fallback: HomeChiefAvatar,
                     harnesses: [String: String], now: Date = Date()) -> HomeRecipientLook {
        guard case .contact(let contact) = recipient, contact.source == .agent else { return HomeRecipientLook() }
        let id = contact.id.rawValue
        let row = rows.first { $0.kind == .chief && $0.summary.participants.contains { $0.id == contact.id } }
        let tag = row.flatMap { self.tag(for: $0.id, engine: ChiefBackend.badge(for: harnesses[id])) }
        return HomeRecipientLook(avatar: avatars[id] ?? fallback, tag: tag, activity: row.map { Self.activity(of: $0, now: now) })
    }

    /// "Active 2 hours ago" for a Chief's conversation, or "No messages yet" for an empty one.
    static func activity(of row: InboxRow, now: Date) -> String {
        guard row.summary.lastSeq > 0 else { return HomeConversationStrings.noMessagesYet }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return HomeConversationStrings.activeAgo(formatter.localizedString(for: min(row.timestamp, now), relativeTo: now))
    }
}

extension HomeChiefRoster {
    /// Who a new group can have, as New Group Chat and Add People to Group list them: the Chiefs
    /// (main first), then the team, then the people of the user's DMs; never `me`.
    /// - Parameters:
    ///   - contacts: New Message's contacts (``HomeContact/merged(team:connections:agents:)``).
    ///   - rows: The inbox rows (the main Chief's conversation names its participant).
    ///   - me: The signed-in participant, left out.
    /// - Returns: Each contact once, in that order.
    public func groupMembers(_ contacts: [HomeContact], rows: [InboxRow], excluding me: ParticipantID?) -> [HomeContact] {
        let ordered = mainFirst(contacts, rows: rows).filter { $0.id != me }
        return [HomeContact.Source.agent, .team, .connection].flatMap { source in ordered.filter { $0.source == source } }
    }
}
