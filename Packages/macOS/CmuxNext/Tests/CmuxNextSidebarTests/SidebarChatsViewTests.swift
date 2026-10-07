import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

@MainActor @Suite struct SidebarChatsViewTests {
    @Test func theSectionIsNamedChats() {
        #expect(SidebarChatsView.title == "Chats")
    }
}
