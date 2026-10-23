import CmuxHomeCore
@testable import CmuxNextHome
import Testing

/// The Home tab keys move through the chat list in sidebar order (the pinned grid, then the rows):
/// next and previous wrap at the ends as a pane's tabs do, and the number keys pick the nth chat,
/// 9 the last (Lawrence 2026-10-21: "cycling through chiefs").
@MainActor
struct HomeChatCyclingTests {
    static var model: HomeSidebarModel {
        HomeSidebarModel(rows: HomeChiefRosterTests.rows, pins: HomePins(), me: HomeChiefRosterTests.me,
                         chiefRoster: HomeChiefRosterTests.roster())
    }

    static var order: [ConversationID] { (model.pinned + model.rows).map(\.id) }

    @Test func nextAndPreviousWrapAtTheEnds() throws {
        let order = Self.order
        try #require(order.count >= 3)
        let last = try #require(order.last)
        #expect(Self.model.neighbor(of: last, offset: 1, wrapping: true) == order.first)
        #expect(Self.model.neighbor(of: order[0], offset: -1, wrapping: true) == last)
        #expect(Self.model.neighbor(of: order[0], offset: 1, wrapping: true) == order[1])
        // Without wrapping (leaving a group selects the next one) the ends still stop.
        #expect(Self.model.neighbor(of: last, offset: 1) == nil)
    }

    @Test func numberKeysPickTheNthChatAndNineTheLast() {
        let order = Self.order
        #expect(Self.model.conversation(number: 1) == order.first)
        #expect(Self.model.conversation(number: 2) == order[1])
        #expect(Self.model.conversation(number: 9) == order.last)
        // Five chats: 6 picks the last, as Ctrl-6 with five tabs does.
        #expect(order.count == 5)
        #expect(Self.model.conversation(number: 6) == order.last)
        #expect(HomeSidebarModel(ordered: [], pinned: [], me: nil).conversation(number: 1) == nil)
    }
}
