import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Testing

/// "New Subgroup" plans one `group.create` under the targeted group, in the group's section
/// (remote-groups-DESIGN.md slice 3). The document allows ``SidebarDocSubgroupPlan/maxDepth`` (16) levels of
/// groups: under a group at that level there is no room, and the plan says so instead of sending an
/// op the daemon refuses.
struct SidebarDocSubgroupPlanTests {
    private let section = "sec_m_mini"

    private func records(chain: Int) -> SidebarDocRecords {
        var items: [String: SidebarDocItem] = [:]
        var parent: String?
        for level in 1...chain {
            let id = "g\(level)"
            items[id] = SidebarDocItem(id: id, section: section, parent: parent, body: .group(name: id, color: nil, icon: nil, collapsed: false))
            parent = id
        }
        return SidebarDocRecords(revision: 1, sections: [section: SidebarDocSection(id: section, kind: .machine(session: "mini"))], items: items)
    }

    @Test func aSubgroupGoesUnderItsParentInTheParentsSection() throws {
        let plan = SidebarDocSubgroupPlan(parent: GroupID("g1"), id: GroupID("g_new"), name: "feat-x", color: .green, records: records(chain: 1))
        let op = try #require(plan.ops?.first)
        #expect(op["op"] as? String == "group.create")
        #expect(op["id"] as? String == "g_new")
        #expect(op["name"] as? String == "feat-x")
        let to = try #require(op["to"] as? [String: Any])
        #expect(to["section"] as? String == section)
        #expect(to["parent"] as? String == "g1")
    }

    @Test func thereIsRoomUnderEveryLevelButTheDeepest() {
        let max = SidebarDocSubgroupPlan.maxDepth
        let below = SidebarDocSubgroupPlan(parent: GroupID("g\(max - 1)"), id: GroupID("n"), name: "", color: .grey, records: records(chain: max - 1))
        #expect(below.ops != nil)
        let deepest = SidebarDocSubgroupPlan(parent: GroupID("g\(max)"), id: GroupID("n"), name: "", color: .grey, records: records(chain: max))
        #expect(deepest.ops == nil)
        #expect(deepest.refusal == .tooDeep)
    }

    /// Lawrence 2026-10-23: "i want to see deeply nested groups". A sixth-level group still takes a subgroup.
    @Test func aSixthLevelGroupTakesASubgroup() {
        let sixth = SidebarDocSubgroupPlan(parent: GroupID("g6"), id: GroupID("n"), name: "", color: .grey, records: records(chain: 6))
        #expect(sixth.ops != nil, "refused: \(String(describing: sixth.refusal))")
    }

    @Test func anUnknownParentPlansNothing() {
        let plan = SidebarDocSubgroupPlan(parent: GroupID("nope"), id: GroupID("n"), name: "", color: .grey, records: records(chain: 1))
        #expect(plan.ops == nil)
        #expect(plan.refusal == .unknownGroup)
    }
}
