import Foundation
import Testing
@testable import CmuxMobileModel

/// The Chats list's filter: the Mac's lists hide archived chats, the Archived scope shows only
/// them, and a search matches title, folder, agent and last prompt (every word).
@Suite struct AgentChatListingTests {
    static let chats = [
        AgentChatListing(id: "a", title: "Fix the build", harness: "claude", cwd: "/Users/me/src/app", status: "running",
                         updatedAt: nil, archived: false),
        AgentChatListing(id: "b", title: nil, harness: "codex", cwd: "/Users/me/src/web", status: "idle",
                         updatedAt: nil, archived: false, lastPrompt: "Café menu"),
        AgentChatListing(id: "c", title: "Old work", harness: "claude", cwd: "/Users/me/src/app", status: "closed",
                         updatedAt: nil, archived: true),
    ]

    @Test func scopesSplitArchivedChats() {
        #expect(AgentChatListing.filter(Self.chats, scope: .chats, query: "").map(\.id) == ["a", "b"])
        #expect(AgentChatListing.filter(Self.chats, scope: .archived, query: "").map(\.id) == ["c"])
    }

    @Test func searchMatchesTitleFolderAgentAndPromptByEveryWord() {
        #expect(AgentChatListing.filter(Self.chats, scope: .chats, query: "BUILD").map(\.id) == ["a"])
        #expect(AgentChatListing.filter(Self.chats, scope: .chats, query: "web").map(\.id) == ["b"])
        #expect(AgentChatListing.filter(Self.chats, scope: .chats, query: "codex cafe").map(\.id) == ["b"])
        #expect(AgentChatListing.filter(Self.chats, scope: .chats, query: "codex build").isEmpty)
        #expect(AgentChatListing.filter(Self.chats, scope: .archived, query: "app").map(\.id) == ["c"])
    }

    @Test func anUntitledChatReadsAsTheMacSaysIt() {
        #expect(AgentChatListing(id: "x", title: "  ", harness: "claude", cwd: "/", status: "idle", updatedAt: nil, archived: false)
            .displayTitle == "New chat")
    }
}
