#if DEBUG
import CmuxNextAgentPane
import Testing

/// `omnibar_history` of `debug.new_tab state` (``AgentPaneOmnibar/recentPageIcons``): the recent pages that a New
/// Tab page opened now would list, each with its address and whether it has an icon, in the bar's order. A bench
/// reads it as the proof that its session has recent pages with icons; the icon's own data is not in the reply.
@Suite struct AgentPaneOmnibarRecentPageIconsTests {
    @Test func eachRecentPageIsListedInTheBarsOrderWithTheSignOfItsIcon() {
        let bar = AgentPaneOmnibar(history: [
            AgentPaneOmnibar.Page(url: "http://127.0.0.1:9001/p/4", title: "four", icon: "data:image/png;base64,iVBORw0KGgo="),
            AgentPaneOmnibar.Page(url: "http://127.0.0.1:9002/p/3", title: "three"),
            AgentPaneOmnibar.Page(url: "http://127.0.0.1:9003/p/3", icon: ""),
            AgentPaneOmnibar.Page(url: "http://127.0.0.1:9001/p/3", icon: "data:image/png;base64,iVBORw0KGgo="),
        ])
        let pages = bar.recentPageIcons
        #expect(pages.map(\.url) == [
            "http://127.0.0.1:9001/p/4", "http://127.0.0.1:9002/p/3", "http://127.0.0.1:9003/p/3", "http://127.0.0.1:9001/p/3",
        ])
        #expect(pages.map(\.icon) == [true, false, false, true])
    }

    @Test func aBarWithNoRecentPageGivesAnEmptyList() {
        #expect(AgentPaneOmnibar().recentPageIcons.isEmpty)
    }
}
#endif
