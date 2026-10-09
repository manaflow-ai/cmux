@testable import CmuxHomeCore
import CmuxNextHome
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-k9go: Mark as Unread on a Home conversation. The owner's unread is a read cursor that only
/// moves forward and the daemon refuses `inbox.mark_unread`, so the mark is kept per account on
/// this Mac, as pins are, and survives a relaunch until the conversation is read.
@MainActor
@Suite struct HomeSidebarUnreadMarkSourceTests {
    typealias Fixture = HomeSidebarSourceTests

    @MainActor final class Account { var id = "user_1" }

    @Test func aMarkShowsUnreadPersistsPerAccountAndClears() {
        let defaults = Fixture.defaults()
        let rows = [Fixture.row("a", "Austin", minutesAgo: 1), Fixture.row("b", "Aziz", minutesAgo: 2)]
        let account = Account()
        func source() -> HomeSidebarSource {
            HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { account.id }, rows: { rows }, me: { Fixture.me },
                              contacts: { [] })
        }
        let first = source()
        first.reloadPins()
        first.setMarkedUnread(true, ConversationID("b"))
        #expect(first.model(now: Fixture.at).rows.first { $0.id.rawValue == "b" }?.unread == true)
        #expect(first.model(now: Fixture.at).rows.first { $0.id.rawValue == "a" }?.unread == false)

        let relaunched = source()
        relaunched.reloadPins()
        #expect(relaunched.unreadMarks == [ConversationID("b")])
        account.id = "user_2"
        relaunched.reloadPins()
        #expect(relaunched.unreadMarks.isEmpty, "another account has its own marks")
        account.id = "user_1"
        relaunched.reloadPins()
        relaunched.setMarkedUnread(false, ConversationID("b"))
        #expect(relaunched.model(now: Fixture.at).rows.allSatisfy { !$0.unread })
        let again = source()
        again.reloadPins()
        #expect(again.unreadMarks.isEmpty)
    }
}
