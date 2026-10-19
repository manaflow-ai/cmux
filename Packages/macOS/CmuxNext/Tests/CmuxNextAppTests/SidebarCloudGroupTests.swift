@testable import CmuxNextSidebar
import Testing

/// The Cloud group (`sidebar.cloudGroup`): a new Cloud workspace joins one
/// group, in an untitled section of its own above the workspace list (each
/// Cloud machine is its own machine section). The reducer side of these ops
/// is `new_cloud_workspaces_of_two_machines_join_one_cloud_group`.
@MainActor @Suite struct SidebarCloudGroupTests {
    static let ref = SidebarDocWorkspaceRef(sessionID: "cloud-b", workspaceID: "w2")

    static func names(_ ops: [[String: Any]]?) -> [String] {
        (ops ?? []).compactMap { $0["op"] as? String }
    }

    @Test func theFirstCloudWorkspaceMakesTheSectionAndTheGroup() throws {
        let ops = try #require(SidebarDocStore.cloudGroupOps([Self.ref], records: SidebarDocRecords(), listSection: "sec_m_local"))
        #expect(Self.names(ops) == ["adopt", "section.add", "group.create"])
        let create = try #require(ops.last)
        #expect(create["id"] as? String == SidebarDocStore.cloudGroupID)
        #expect(create["items"] as? [String] == [SidebarDocStore.adoptedID(Self.ref)])
        #expect((ops[1]["place"] as? [String: Any])?["before"] as? String == "sec_m_local", "the section goes above the workspace list")
    }

    @Test func aLaterCloudWorkspaceMovesIntoTheGroup() throws {
        var records = SidebarDocRecords()
        records.sections[SidebarDocStore.cloudSectionID] = SidebarDocSection(id: SidebarDocStore.cloudSectionID, kind: .custom)
        records.items[SidebarDocStore.cloudGroupID] = SidebarDocItem(id: SidebarDocStore.cloudGroupID, section: SidebarDocStore.cloudSectionID,
                                                                     body: .group(name: "Cloud", color: nil, icon: nil, collapsed: false))
        let placed = SidebarDocItem(id: "itm_w2", section: "sec_m_cloud-b", body: .workspace(Self.ref))
        records.items[placed.id] = placed
        let ops = try #require(SidebarDocStore.cloudGroupOps([Self.ref], records: records, listSection: nil))
        #expect(Self.names(ops) == ["move"])
        #expect(ops[0]["items"] as? [String] == ["itm_w2"])
        #expect((ops[0]["to"] as? [String: Any])?["parent"] as? String == SidebarDocStore.cloudGroupID)
    }

    @Test func aWorkspaceAlreadyInAGroupStaysThere() {
        var records = SidebarDocRecords()
        let grouped = SidebarDocItem(id: "itm_w2", section: "sec_m_cloud-b", parent: "grp_mine", body: .workspace(Self.ref))
        records.items[grouped.id] = grouped
        #expect(SidebarDocStore.cloudGroupOps([Self.ref], records: records, listSection: nil) == nil)
    }
}
