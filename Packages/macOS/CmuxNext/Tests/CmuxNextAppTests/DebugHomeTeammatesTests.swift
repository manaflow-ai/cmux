@testable import CmuxHomeCore
import CmuxNextHome
import Foundation
import Testing
@testable import CmuxNextApp

/// debug.home's teammate count: the contacts the user has no DM with, so a
/// run can tell an absent Teammates search section from a broken one.
@MainActor
@Suite struct DebugHomeTeammatesTests {
    @Test func countsContactsWithoutADirectConversation() {
        let rows = [HomeSidebarSourceTests.row("a", "Austin", minutesAgo: 1)]
        let austin = HomeContact(id: ParticipantID("user_a"), name: "Austin", source: .team)
        let zoe = HomeContact(id: ParticipantID("user_zoe"), name: "Zoe", source: .team)
        #expect(DebugHome.teammatesWithoutDM(rows: rows, contacts: [austin, zoe]) == 1, "Austin already has a DM")
        #expect(DebugHome.teammatesWithoutDM(rows: rows, contacts: [austin]) == 0)
    }
}
