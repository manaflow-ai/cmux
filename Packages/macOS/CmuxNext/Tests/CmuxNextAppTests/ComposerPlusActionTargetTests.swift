import CmuxNextActions
@testable import CmuxNextApp
import Testing

@MainActor
struct ComposerPlusActionTargetTests {
    @Test func searchTabsOpensSearchInsteadOfRevealingTheCurrentTab() {
        let search = AgentTabStore.composerActionInvocation("tab.search", tab: "chat-tab", arguments: [:])
        #expect(search.target == nil)

        let browser = AgentTabStore.composerActionInvocation("openBrowser", tab: "chat-tab", arguments: [:])
        #expect(browser.target?.kind == .tab)
        #expect(browser.target?.id == "chat-tab")
    }
}
