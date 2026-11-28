import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-26 ("what is the stuff under Chief? ... ideally Chief is just a single line"): the sidebar
/// drew one indented row per Chief subagent under the Chief, most titled "<chat>". The Chief is one line now;
/// its subagents stay listed in the Chief pane's Subagents menu.
@MainActor
struct ChiefSingleLineSidebarTests {
    @Test func theChiefsSubagentsNeverDrawAsSidebarRows() {
        let store = AgentLaneStore()
        let lanes = (1...6).map {
            AgentActivityLane(id: "id-\($0)", name: "optchat-sub-6b68ac4a-a\($0)", title: "<chat>", peer: nil,
                              parent: "optchat-chief:6b68ac4a", state: .failed, since: nil, error: nil, harness: "claude")
        }
        let chief = ChiefSidebar(lanes: store)
        for lane in lanes { store.lanes[lane.id] = lane }
        #expect(chief.allSubagents().count == 6, "the Chief pane's menu still lists them")
        #expect(!SidebarModel.topItems(chief: chief).contains { SidebarTransientItem.chiefSubagentSession($0.item.id) != nil })
    }
}
