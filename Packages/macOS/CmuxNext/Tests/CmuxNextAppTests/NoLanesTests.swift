@testable import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20: "get rid of lanes thing". The sidebar has no Lanes item and the Agent
/// Activity page has no lanes view, even while agent sessions need a person. The lane store still
/// feeds the Priority view, the Chief item and the session tree.
@MainActor
struct NoLanesTests {
    private static let failed = AgentActivityLane(id: "op-broke", name: "op-broke", title: "op-broke", peer: nil, parent: nil,
                                                  state: .failed, since: nil, error: "Credit balance too low")

    @Test func theSidebarShowsNoLanesItem() {
        let store = AgentLaneStore()
        store.lanes = [Self.failed.id: Self.failed]
        let lanesID = LayoutItemID(LayoutItemID.transientPrefix + "lanes")
        #expect(!SidebarModel.topItems(lanes: store).contains { $0.item.id == lanesID })
    }

    @Test func theAgentActivityPageHasNoLanesStrings() {
        let page = AgentActivityStrings.page
        #expect(page["lanes"] == nil, "no Lanes tab title")
        #expect(!page.keys.contains { $0.hasPrefix("lane") }, "no lanes view strings")
    }
}
