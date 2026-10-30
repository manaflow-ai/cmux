@testable import CmuxNextApp
import Testing

/// The title menu's Move to machine is bound to the chat whose menu was opened (cmux#25661): the
/// host moves the tab only while it still shows that chat.
struct AgentTitleMoveBindingTests {
    @Test func movesOnlyTheMenusChat() {
        #expect(AgentTabStore.tabStillShows("chat-a", requested: "chat-a"))
        #expect(!AgentTabStore.tabStillShows("chat-b", requested: "chat-a"))
        #expect(!AgentTabStore.tabStillShows(nil, requested: "chat-a"))
        #expect(!AgentTabStore.tabStillShows("chat-a", requested: ""))
    }
}
