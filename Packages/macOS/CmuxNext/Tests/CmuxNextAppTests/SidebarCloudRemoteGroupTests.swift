import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A Cloud machine's workspaces sit in one group: New Cloud Workspace and a new Cloud machine mark
/// the machine's section a remote group (`RemoteGroupHandlers.mark`, `SidebarDocStore.markHostGroup`). In one list, the
/// Cloud machine keeps its header, every one of its workspaces draws under it, and its nested groups
/// indent inside it; this Mac's workspaces stay header-less rows.
@MainActor struct SidebarCloudRemoteGroupTests {
    private let cloud = MachineID("cloud-vm"), project = GroupID("g_project"), branch = GroupID("g_branch")

    private func sections() -> [SidebarSection] {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("local"), name: "This Mac", kind: .local)),
                                   nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("l1"), title: "l1"))])
        func group(_ id: GroupID, parent: GroupID?, depth: Int, _ members: [String]) -> SidebarNode {
            var made = SidebarGroup(id: id, name: id.rawValue, workspaces: members.map { SidebarWorkspace(id: WorkspaceID($0), title: $0) })
            made.parent = parent
            made.depth = depth
            return .group(made)
        }
        var machine = SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud)), nodes: [
            group(project, parent: nil, depth: 0, ["c1"]),
            group(branch, parent: project, depth: 1, ["c2"]),
            .workspace(SidebarWorkspace(id: WorkspaceID("c3"), title: "c3")),
        ])
        machine.isHostGroup = true
        return [local, machine]
    }

    private func rows() -> [SidebarRow] {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: options).rows
    }

    @Test func everyCloudWorkspaceDrawsUnderTheMachinesOneHeader() throws {
        let rows = rows()
        let headers = rows.filter { if case .section = $0.key { true } else { false } }
        #expect(headers.map(\.key) == [.section(.machine(cloud))], "only the Cloud machine has a header")
        let header = try #require(rows.firstIndex { $0.key == .section(.machine(cloud)) })
        for id in ["c1", "c2", "c3"] {
            let at = try #require(rows.firstIndex { $0.key == .workspace(WorkspaceID(id)) })
            #expect(at > header, "\(id) is under the Cloud header")
            #expect(rows[at].section == .machine(cloud))
        }
        #expect(rows.contains { $0.key == .workspace(WorkspaceID("l1")) }, "this Mac's row stays in the one list")
    }

    @Test func nestedGroupsIndentInsideTheCloudGroup() {
        let rows = rows()
        let depth = { (key: SidebarRowKey) in rows.first { $0.key == key }?.depth }
        #expect(depth(.group(project)) == 0)
        #expect(depth(.group(branch)) == 1)
        #expect(depth(.workspace(WorkspaceID("c2"))) == 2)
        #expect(rows.first { $0.key == .workspace(WorkspaceID("c2")) }?.group == branch)
    }
}
