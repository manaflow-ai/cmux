public import CmuxHomeCore
public import Foundation

/// The Chiefs and people New Message and New Group Chat list: the main Chief first, then the rest.
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

    /// The Chiefs New Message lists before anything is typed, as Messages lists recent conversations: the main
    /// Chief, and every Chief whose conversation has a message from the last `within` (14 days) or was made in it. A Chief with no
    /// messages, or none lately, is left out of that list, not hidden: typing its name in To: still finds it, and the
    /// Home list still shows it. Everyone else in `contacts` (the team, people of DMs) stays, in order (#48467: the
    /// list showed six Chiefs, most of them old, idle ones).
    /// - Parameters:
    ///   - contacts: New Message's contacts, main Chief first (``mainFirst(_:rows:)``).
    ///   - rows: The inbox rows (each Chief's own conversation has its last message's time).
    ///   - now: The time `within` counts back from.
    ///   - within: How recent a Chief's last message must be.
    /// - Returns: `contacts` without the Chiefs that are neither main nor recent.
    public func recentChiefs(_ contacts: [HomeContact], rows: [InboxRow], now: Date = Date(),
                             within: TimeInterval = Self.recentChiefWindow) -> [HomeContact] {
        let chiefRows = rows.filter { $0.kind == .chief }
        return contacts.filter { contact in
            guard contact.source == .agent else { return true }
            let own = chiefRows.filter { $0.summary.participants.contains { $0.id == contact.id } }
            if let main, own.contains(where: { $0.id == main }) { return true }
            // A message lately, or a Chief made lately (New Chief: listed before its first message).
            let since = now.addingTimeInterval(-within)
            return own.contains { ($0.summary.lastSeq > 0 && $0.timestamp >= since) || $0.summary.createdAt >= since }
        }
    }

    /// How recent a Chief's last message must be for New Message to list it before anything is typed: 14 days.
    public static let recentChiefWindow: TimeInterval = 14 * 24 * 60 * 60

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
