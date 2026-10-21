public import CmuxHomeCore
import Foundation

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
    /// - Returns: The row's avatar and tag.
    public func look(_ recipient: HomeRecipient, rows: [InboxRow], avatars: [String: HomeChiefAvatar], fallback: HomeChiefAvatar,
                     harnesses: [String: String]) -> HomeRecipientLook {
        guard case .contact(let contact) = recipient, contact.source == .agent else { return HomeRecipientLook() }
        let id = contact.id.rawValue
        let row = rows.first { $0.kind == .chief && $0.summary.participants.contains { $0.id == contact.id } }
        let tag = row.flatMap { self.tag(for: $0.id, engine: ChiefBackend.badge(for: harnesses[id])) }
        return HomeRecipientLook(avatar: avatars[id] ?? fallback, tag: tag)
    }
}
