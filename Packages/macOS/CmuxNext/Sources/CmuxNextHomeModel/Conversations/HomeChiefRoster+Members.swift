public import CmuxHomeCore

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
