import CmuxNextLayout
@testable import CmuxNextApp
import Testing

struct ChatColumnPlacementTests {
    enum Tab: Equatable, Sendable {
        case chat, newTab, terminal, browser, file, diff
    }

    @Test(arguments: [
        ([Tab.chat], true),
        ([Tab.chat, .newTab], true),
        ([Tab.chat, .newTab, .newTab], true),
        ([Tab.newTab, .chat], true),
        ([Tab.chat, .terminal], false),
        ([Tab.chat, .newTab, .terminal], false),
        ([Tab.chat, .chat], false),
        ([Tab.newTab], false),
        ([Tab.chat, .browser], false),
        ([Tab.chat, .file], false),
        ([Tab.chat, .diff], false),
        ([], false),
    ])
    func onlyNewTabPagesMayAccompanyALoneChat(tabs: [Tab], expected: Bool) {
        let chat = ChatColumnPlacement.loneChat(in: tabs, isChat: { $0 == .chat }, isNewTabPage: { $0 == .newTab })
        #expect((chat != nil) == expected)
    }

    @Test func aNewTabPageBeforeTheChatDoesNotBecomeTheDockedTab() throws {
        let tabs: [Tab] = [.newTab, .chat]
        let chat = ChatColumnPlacement.loneChat(in: tabs, isChat: { $0 == .chat }, isNewTabPage: { $0 == .newTab })
        let dockedChat = try #require(chat)
        #expect(dockedChat == .chat)
        let columns = [LayoutColumn(id: "column", root: .leaf("pane"))]
        let placement = ChatColumnPlacement.resolve(from: "pane", columns: columns) { _ in chat != nil }
        #expect(placement == .dockChat)
        #expect(NewChatPlacement.resolve(from: "pane", columns: columns, isLoneChat: placement == .dockChat) == .here)
    }
}
