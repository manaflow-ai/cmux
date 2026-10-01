@testable import CmuxNextApp
import Testing

@MainActor
struct AgentTabStoreTests {
    @Test func closingAPaneForgetsItsAgentTabsOnly() {
        let store = AgentTabStore(tag: nil, environment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        _ = store.open(in: "a")
        _ = store.open(in: "a")
        let kept = store.open(in: "b")
        store.closePane("a")
        #expect(store.tabIDs(in: "a").isEmpty)
        #expect(store.tabIDs(in: "b") == [kept])
    }
}
