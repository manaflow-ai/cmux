@testable import CmuxNextAgentPane
import Testing

/// Leo, ask-acaf57cddd (2026-11-27): "for some reason the new tab page is sometimes opening as just [a screenshot of
/// the empty chat] idk some agent chat view?". A New Tab tab adopts a page view (the spare, or the untouched page of
/// another New Tab tab: `AgentTabStore.adoptSpare(_:key:page:)`). The model ignored that context when its page had
/// no New Tab context, so a page with no chat stayed the empty chat in a tab titled New Tab. Want: a page with no
/// chat takes the context and is that tab's New Tab page; a page with a chat keeps its chat.
@MainActor @Suite
struct NewTabAdoptOfChatlessPageTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    @Test func aPageWithNoChatBecomesTheTabsNewTabPage() throws {
        let model = AgentPaneModel(host: Host())
        try #require(model.newTab == nil && model.sessionId == nil, "setup: the page is a plain chat page with no chat")
        let page = AgentPaneNewTab(kind: .agent, cwd: "/tabs/project")
        model.adoptNewTab(page)
        #expect(model.newTab == page, "a New Tab tab's context was ignored by a page with no chat: the tab draws a bare chat")
        #expect(model.newTabForPage != nil, "the page gets no New Tab context to draw")
    }

    @Test func aPageWithAChatKeepsItsChat() {
        let model = AgentPaneModel(host: Host(), sessionId: "chat-1")
        model.adoptNewTab(AgentPaneNewTab(kind: .agent, cwd: "/tabs/project"))
        #expect(model.newTab == nil, "a page that shows a chat became a New Tab page")
        #expect(model.sessionId == "chat-1")
    }

    @Test func aNewTabPageTakesTheNextTabsContext() {
        let model = AgentPaneModel(host: Host(), newTab: AgentPaneNewTab(kind: .agent))
        let page = AgentPaneNewTab(kind: .agent, cwd: "/next/tab")
        model.adoptNewTab(page)
        #expect(model.newTab == page)
    }
}
