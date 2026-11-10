import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import MessagesLabSidebar
import Testing

/// Home's contacts for a new conversation, and the people and rows other Home tests share. The
/// New Message page itself (its To: field, tokens and suggestions) moved to the React Messages
/// page (`webviews/src/pages/home-messages`), whose own tests cover it.
@MainActor
struct HomeNewMessageTests {
    static let me = ParticipantID("me")
    static let ada = HomeContact(id: ParticipantID("ada"), name: "Ada Lovelace", source: .team)
    static let alan = HomeContact(id: ParticipantID("alan"), name: "Alan Turing", source: .connection)
    static let grace = HomeContact(id: ParticipantID("grace"), name: "Grace Hopper", source: .team)
    static let chief = HomeContact(id: ParticipantID("chief-1"), name: "Chief", source: .agent)
    static let contacts = [ada, alan, grace, chief]

    // MARK: Contacts

    @Test func newMessageOffersTheUsersChiefsAfterPeople() {
        let chiefParticipant = Participant(id: Self.chief.id, kind: .agent, displayName: "Chief", agentClass: .chief)
        let rows = [Self.row("chief", participants: [chiefParticipant])]
        let agents = HomeContact.agents(in: rows, me: Self.me)
        #expect(agents == [HomeContact(id: Self.chief.id, name: "Chief", source: .agent)])
        let merged = HomeContact.merged(team: [Self.grace, Self.ada], connections: [Self.alan, Self.ada], agents: agents)
        #expect(merged.map(\.id) == [Self.ada.id, Self.grace.id, Self.alan.id, Self.chief.id])
    }

    /// One inbox row as the store derives it (its kind from its members: one human is a DM, a
    /// Chief is the Chief's conversation, two or more others a group).
    static func row(_ id: String, _ others: [ParticipantID]) -> InboxRow {
        row(id, participants: others.map { other in
            other == chief.id ? Participant(id: other, kind: .agent, displayName: "Chief", agentClass: .chief)
                : Participant(id: other, kind: .human, displayName: other.rawValue)
        })
    }

    static func row(_ id: String, participants: [Participant]) -> InboxRow {
        let at = Date(timeIntervalSince1970: 1_000)
        let mine = Participant(id: me, kind: .human, displayName: "Me")
        let summary = ConversationSummary(id: ConversationID(id), participants: [mine] + participants, createdAt: at, updatedAt: at)
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: mine, conversations: [summary], rev: 1))
        return mirror.inboxRows(log: IntentLog())[0]
    }
}
