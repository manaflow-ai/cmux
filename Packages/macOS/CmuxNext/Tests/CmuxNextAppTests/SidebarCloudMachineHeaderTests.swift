import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-29: "why is there all this weird stuff at the bottom of the sidebar". In one list a Cloud machine's
/// rows floated under this Mac's last group with no machine over them. Each Cloud machine with workspaces keeps its
/// machine header, as a remote group does.
@MainActor struct SidebarCloudMachineHeaderTests {
    private func machine(_ name: String, kind: SidebarMachine.Kind, _ ids: [String]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)),
                       nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0, directory: "~")) })
    }

    private func layout(_ sections: [SidebarSection]) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    private var sections: [SidebarSection] {
        [machine("local", kind: .local, ["ws_mac"]), machine("build-vm", kind: .cloud, ["ws_a"]),
         machine("paused", kind: .cloud, []), machine("dev-vm", kind: .cloud, ["ws_b"])]
    }

    @Test func eachCloudMachineWithWorkspacesHasItsHeaderOverThem() {
        let keys = layout(sections).rows.map(\.key)
        #expect(keys == [.workspace(WorkspaceID("ws_mac")),
                         .section(.machine(MachineID("build-vm"))), .workspace(WorkspaceID("ws_a")),
                         .section(.machine(MachineID("dev-vm"))), .workspace(WorkspaceID("ws_b"))])
    }

    @Test func anotherComputerInOneListStillHasNoHeader() {
        let keys = layout([machine("local", kind: .local, ["ws_mac"]), machine("vm", kind: .ssh, ["ws_vm"])]).rows.map(\.key)
        #expect(!keys.contains { if case .section = $0 { true } else { false } })
    }

    /// The only machine's header titles the list "Projects" with no machine icon (`SidebarRow.titlesProjects`); a Cloud
    /// machine's header is there to say which machine, so it keeps its name, icon and status.
    @Test func theOnlyMachineBeingCloudKeepsItsOwnHeader() throws {
        let rows = layout([machine("dev-vm", kind: .cloud, ["ws_b"])]).rows
        let header = try #require(rows.first { $0.key == .section(.machine(MachineID("dev-vm"))) })
        #expect(!header.titlesProjects)
    }
}
