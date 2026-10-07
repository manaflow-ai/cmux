import CmuxNextActions
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// The sidebar's Search Chats opens the command palette's chats page
/// (`agentPane.searchChats`); there is no second chats search.
@MainActor @Suite struct AgentChatSearchPageTests {
    @Test func theSidebarItemRunsTheChatsPage() {
        #expect(SidebarBridge.builtInActions[.searchChats] == "agentPane.searchChats")
    }

    @Test func thereIsNoSecondChatsSearch() {
        #expect(!ActionCatalog.all.contains { $0.id == "agentChats.search" })
    }
}
