#if DEBUG || CMUX_BENCH_HOOKS
import CmuxHomeCore

/// DEBUG ONLY: fixture rows for captures of the list under To: (`debug.home.sidebar_fixture`
/// `new_message`), with no signed-in account: four Chiefs (two read "Chief · This Mac" alike) and `team`.
extension HomeRecipientField {
    /// Lists the fixture Chiefs and `team` as the idle list, then shows it.
    /// - Parameter team: The fixture teammates' names.
    public func debugFillFixture(team: [String]) {
        let chiefs: [(HomeContact, String, String)] = [
            (HomeContact(id: ParticipantID("agent_fixture_main"), name: "Chief", source: .agent), "Main \u{00B7} Cloud", "Active 3 minutes ago"),
            (HomeContact(id: ParticipantID("agent_fixture_codex"), name: "Chief Codex", source: .agent), "This Mac \u{00B7} Codex", "Active 1 hour ago"),
            (HomeContact(id: ParticipantID("agent_fixture_mac_1"), name: "Chief", source: .agent), "This Mac", "Active 2 hours ago"),
            (HomeContact(id: ParticipantID("agent_fixture_mac_2"), name: "Chief", source: .agent), "This Mac", HomeConversationStrings.noMessagesYet),
        ]
        let members = team.enumerated().map { HomeContact(id: ParticipantID("user_fixture_team_\($0)"), name: $1, source: .team) }
        idleSuggestions = { chiefs.map(\.0) + members }
        suggestions.look = { recipient in
            guard case .contact(let contact) = recipient, let chief = chiefs.first(where: { $0.0 == contact }) else { return HomeRecipientLook() }
            return HomeRecipientLook(avatar: .chiefDefault, tag: chief.1, activity: chief.2)
        }
        refreshSuggestions()
    }
}
#endif
