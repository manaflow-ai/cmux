import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import MessagesLabSidebar
import Testing

/// A Chief's avatar in the Home list and pinned grid draws only what Messages draws on a pinned
/// avatar (the unread dot, the typing bubble): no ring, arc, dots or badge for what the Chief is
/// doing (the user, 2026-11-04: "i dont want to see the blue thing in chief, no special things
/// besides unread and other stuff").
@MainActor
struct HomeChiefAvatarPlainTests {
    /// What a Chief can be doing while its row is listed: its turn running, or a reply unread.
    enum State: String, CaseIterable, Sendable {
        case working, unreadReply
    }

    static func chiefItem() throws -> HomeSidebarItem {
        let id = CmuxHomeCore.ConversationID("conv_chief")
        let row = HomeChiefRosterTests.chief(id, "agent_mux", "Chief", at: 1)
        let model = HomeSidebarModel(rows: [row], pins: HomePins(), me: HomeChiefRosterTests.me)
        var item = try #require((model.pinned + model.rows).first { $0.id == id })
        item.chiefAvatar = .text("C")
        return item
    }

    @Test(arguments: State.allCases)
    func aChiefsLiveStateLeavesItsAvatarPlain(_ state: State) throws {
        let idle = try Self.chiefItem()
        var busy = idle
        switch state {
        case .working: busy.chiefIsWorking = true
        case .unreadReply: busy.unread = true
        }
        #expect(HomeSidebarView.entry(busy) == HomeSidebarView.entry(idle),
                "the list entry, and so the avatar it draws, is the same in every Chief state")
    }
}
