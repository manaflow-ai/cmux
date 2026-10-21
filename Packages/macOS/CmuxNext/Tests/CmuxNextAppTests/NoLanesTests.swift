@testable import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20: "get rid of lanes thing". The sidebar has no Lanes item and the Agent
/// Activity page has no lanes view. The lane store still feeds the Priority view, the Chief item
/// and the session tree.
@MainActor
struct NoLanesTests {
    @Test func theSidebarShowsNoLanesItem() {
        let lanesID = LayoutItemID(LayoutItemID.transientPrefix + "lanes")
        #expect(!SidebarModel.topItems().contains { $0.item.id == lanesID })
    }

    @Test func theAgentActivityPageHasNoLanesStrings() {
        let page = AgentActivityStrings.page
        #expect(page["lanes"] == nil, "no Lanes tab title")
        #expect(!page.keys.contains { $0.hasPrefix("lane") }, "no lanes view strings")
    }
}
