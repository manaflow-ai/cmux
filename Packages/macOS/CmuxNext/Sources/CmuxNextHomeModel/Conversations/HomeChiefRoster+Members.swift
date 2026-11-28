public import CmuxHomeCore

/// The Chiefs and people New Message and New Group Chat list: the main Chief first, then the rest.
extension HomeChiefRoster {
    /// `contacts` with the main Chief first (before a list's limit can cut it) (`inbox.roster_main_first`).
    /// - Parameters:
    ///   - contacts: New Message's contacts.
    ///   - rows: The inbox rows (the main Chief's conversation names its participant).
    /// - Returns: The same contacts, the main Chief moved to the front.
    public func mainFirst(_ contacts: [HomeContact], rows: [InboxRow]) -> [HomeContact] {
        HomeContact.contacts("roster_main_first", RosterRequest(contacts: contacts.map(\.rules), rows: HomeInboxRules().rows(rows),
                                                                main: main?.rawValue, me: nil))
    }

    /// Who a new group can have, as New Group Chat and Add People to Group list them: the Chiefs
    /// (main first), then the team, then the people of the user's DMs; never `me` (`inbox.roster_group_members`).
    /// - Parameters:
    ///   - contacts: New Message's contacts (``HomeContact/merged(team:connections:agents:)``).
    ///   - rows: The inbox rows (the main Chief's conversation names its participant).
    ///   - me: The signed-in participant, left out.
    /// - Returns: Each contact once, in that order.
    public func groupMembers(_ contacts: [HomeContact], rows: [InboxRow], excluding me: ParticipantID?) -> [HomeContact] {
        HomeContact.contacts("roster_group_members", RosterRequest(contacts: contacts.map(\.rules), rows: HomeInboxRules().rows(rows),
                                                                   main: main?.rawValue, me: me?.rawValue))
    }
}

private nonisolated struct RosterRequest: Encodable {
    var contacts: [HomeInboxRules.Contact]
    var rows: [HomeInboxRules.Row]
    var main: String?
    var me: String?
}
