import CmuxNextAgentPane
import CmuxNextPalette
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// The sidebar's Search Chats: a palette page over every agent chat, newest
/// first as the feed hands them over; a row opens its chat.
@MainActor @Suite struct AgentChatSearchPageTests {
    @Test func rowsFollowTheChatsAndOpenTheirChat() throws {
        let chats = [AcpmuxRecentChat(id: "a", title: "Fix CI", harness: "claude", cwd: "/src/cmux", updatedAt: 2),
                     AcpmuxRecentChat(id: "b", title: nil, harness: "codex", updatedAt: 1)]
        var opened: [String] = []
        let page = AgentChatSearchHandlers.page(chats) { opened.append($0) }
        let rows = try #require(page.providers.first?.immediateItems)
        #expect(rows.map(\.title) == ["Fix CI", "New chat"])
        #expect(rows.map(\.subtitle) == ["cmux", nil])
        #expect(rows.map(\.brand) == ["claude", "codex"])
        guard case .perform(let run) = try #require(rows.last).primary.effect else { Issue.record("not a perform"); return }
        run()
        #expect(opened == ["b"])
    }

    @Test func theSidebarItemRunsSearchChats() {
        #expect(SidebarBridge.builtInActions[.searchChats] == "agentChats.search")
    }
}
