import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// The user, 2026-10-21: "for compose button default should make it look like imessage, so the
/// compose button is always in the body area not the sidebar, even on big screen sizes. and by
/// default i should be able to see everyone in my team as people i can chat to". Compose and the
/// list are drawn by the React Messages page now; the list's model stays native.
@MainActor
struct HomeComposeAndTeamTests {
    static let me = HomeNewMessageTests.me
    static let ada = HomeNewMessageTests.ada
    static let alan = HomeNewMessageTests.alan
    static let grace = HomeNewMessageTests.grace
    static let chief = HomeNewMessageTests.chief
    static let contacts = HomeNewMessageTests.contacts

    // MARK: The team in the list

    /// With no search, every team member the user has no DM with is listed as someone to chat to;
    /// people already in a DM, connections outside the team and Chiefs are not listed twice.
    @Test func teammatesWithoutADMAreListedByDefault() {
        let rows = [HomeNewMessageTests.row("dm-grace", [Self.grace.id]), HomeNewMessageTests.row("chief", [Self.chief.id])]
        let model = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, contacts: Self.contacts)
        #expect(model.teammates == [Self.ada])
        let searched = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me, query: "ada", contacts: Self.contacts)
        #expect(searched.teammates.isEmpty, "the search lists teammates in its own section")
        #expect(searched.people == [Self.ada])
    }

    /// The user, 2026-10-29: "there are 2 austins now?". The cmux team holds two accounts of one
    /// person (Austin Wang, a work and a personal sign-in): the list had his DM and a teammate row
    /// for his other account, and choosing that row made a second, empty Austin DM. One name is one
    /// person in the list: a teammate named like a DM peer, or like a teammate listed already, gets
    /// no row of its own (New Message's search still finds each account).
    @Test func aNameAlreadyListedGetsNoSecondTeammateRow() {
        let work = HomeContact(id: ParticipantID("austin-work"), name: "Austin Wang", source: .team)
        let personal = HomeContact(id: ParticipantID("austin-personal"), name: "Austin Wang", source: .team)
        let dm = HomeNewMessageTests.row("dm-austin", participants: [Participant(id: work.id, kind: .human, displayName: "Austin Wang")])
        let withDM = HomeSidebarModel(rows: [dm], pins: HomePins(), me: Self.me, contacts: [work, personal, Self.ada])
        #expect(withDM.teammates == [Self.ada])
        let noDM = HomeSidebarModel(rows: [], pins: HomePins(), me: Self.me, contacts: [work, personal, Self.ada])
        #expect(noDM.teammates == [work, Self.ada])
        let searched = HomeSidebarModel(rows: [dm], pins: HomePins(), me: Self.me, query: "austin", contacts: [work, personal])
        #expect(searched.people == [personal], "the search reaches the other account")
    }
}
