@testable import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxNextHome

/// cx-k9go: a conversation the user marked unread (Mark as Unread) shows unread, with the dot and a
/// count of one, until it is read; real unread messages keep their own count.
@Suite struct HomeSidebarUnreadMarkTests {
    typealias Fixture = HomeSidebarModelTests

    static func model(marks: Set<ConversationID>) -> HomeSidebarModel {
        HomeSidebarModel(rows: Fixture.rows.orderedForInbox(), pins: HomePins(), me: Fixture.me, unreadMarks: marks,
                         now: Fixture.now, calendar: Fixture.calendar, locale: Fixture.locale)
    }

    static func item(_ model: HomeSidebarModel, _ id: String) -> HomeSidebarItem? {
        (model.pinned + model.rows).first { $0.id.rawValue == id }
    }

    @Test func aMarkedReadConversationShowsUnread() throws {
        let item = try #require(Self.item(Self.model(marks: [ConversationID("conv_aziz")]), "conv_aziz"))
        #expect(item.unread)
        #expect(item.unreadCount == 1)
        #expect(item.accessibilityLabel.contains("1 unread"))
        let entry = HomeSidebarView.entry(item)
        #expect(entry.unreadCount == 1, "the list draws its unread dot")
    }

    @Test func withoutTheMarkItIsRead() throws {
        let item = try #require(Self.item(Self.model(marks: []), "conv_aziz"))
        #expect(!item.unread && item.unreadCount == 0)
    }

    @Test func aMarkNeverLowersRealUnreadMessages() throws {
        let item = try #require(Self.item(Self.model(marks: [ConversationID("conv_lucas")]), "conv_lucas"))
        #expect(item.unreadCount == 1)
    }
}
