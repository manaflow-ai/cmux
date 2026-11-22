public import CmuxHomeCore
public import CmuxNextHomeModel
public import Foundation

/// The Chiefs as New Message's list under To: shows them: each row tagged where it runs as the
/// Home list tags it ("Chief · Main · Cloud", "Chief · This Mac"), so two Chiefs named alike tell
/// apart (the main Chief comes first: ``HomeChiefRoster/mainFirst(_:rows:)``).
extension HomeChiefRoster {
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
