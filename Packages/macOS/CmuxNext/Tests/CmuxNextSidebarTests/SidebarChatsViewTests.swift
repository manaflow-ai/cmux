import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

@MainActor @Suite struct SidebarChatsViewTests {
    @Test func theSectionIsNamedAllChats() {
        #expect(SidebarChatsView.title == "All chats")
    }
}
