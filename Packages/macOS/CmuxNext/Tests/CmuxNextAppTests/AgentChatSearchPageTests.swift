import CmuxNextActions
import CmuxNextIcons
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// The sidebar's Search Chats opens the command palette's chats page
/// (`agentPane.searchChats`); there is no second chats search. It is an item
/// a user adds (Add to Sidebar…), not a default: the top stays Home, then the
/// App Store (S1).
@MainActor @Suite struct AgentChatSearchPageTests {
    @Test func theSidebarItemRunsTheChatsPage() {
        #expect(SidebarBridge.builtInActions[.searchChats] == "agentPane.searchChats")
        #expect(SidebarBuiltIn.searchChats.title == "Search Chats")
        #expect(SidebarBuiltIn.searchChats.icon == .search)
    }

    @Test func thereIsNoSecondChatsSearch() {
        #expect(!ActionCatalog.all.contains { $0.id == "agentChats.search" })
    }

    @Test func searchChatsIsAddableButNotADefault() throws {
        let top = SidebarLayoutDocument.defaults.sections(in: .top, room: nil).flatMap(\.items).map(\.id.rawValue)
        #expect(top == ["itm_home", "itm_app_store"])
        #expect(!SidebarLayoutDocument.defaults.sections.flatMap(\.items).contains { $0.ref == .builtIn(.searchChats) })
        let add = try #require(ActionCatalog.all.first { $0.id == "sidebar.item.add" })
        let item = try #require(add.arguments.first { $0.name == "item" })
        // The item is free text (`workspace:` / `app:` refs, PINNED-ITEMS-END-TO-END P1) with the built-ins offered.
        let offered = item.suggestions?.pinned.map(\.value) ?? []
        #expect(offered.contains("search_chats"))
    }
}
