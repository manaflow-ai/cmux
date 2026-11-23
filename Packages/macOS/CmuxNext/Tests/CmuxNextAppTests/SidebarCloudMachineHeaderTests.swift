import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// 2026-11-10, of a Cloud chat's workspace under a collapsible "lease-lease_21_c6c…" header with a chevron and a +: no
/// machine group, ever. A Cloud machine's workspaces are ordinary rows of the one list, each with a cloud mark by its
/// name, and the machine's name shows nowhere in the sidebar (no header, no row label). A remote group a person made
/// keeps its header (`SidebarCloudRemoteGroupTests`); `sidebar.groupByComputer` still heads every computer.
@MainActor struct SidebarCloudMachineHeaderTests {
    private func machine(_ name: String, kind: SidebarMachine.Kind, _ ids: [String]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)),
                       nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), machineID: MachineID(name), title: $0, directory: "~")) })
    }

    private func layout(_ sections: [SidebarSection]) -> SidebarLayout {
        let model = SidebarModel(sections: sections)
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
    }

    private var sections: [SidebarSection] {
        [machine("local", kind: .local, ["ws_mac"]), machine("lease-lease_21_c6c", kind: .cloud, ["ws_a"]),
         machine("paused", kind: .cloud, []), machine("vm_dev", kind: .cloud, ["ws_b"])]
    }

    @Test func cloudWorkspacesAreOrdinaryRowsWithNoMachineHeader() {
        let keys = layout(sections).rows.map(\.key)
        #expect(keys == [.workspace(WorkspaceID("ws_mac")), .workspace(WorkspaceID("ws_a")), .workspace(WorkspaceID("ws_b"))])
    }

    @Test func theOnlyMachineBeingCloudHasNoHeaderEither() {
        let keys = layout([machine("vm_dev", kind: .cloud, ["ws_b"])]).rows.map(\.key)
        #expect(!keys.contains { if case .section = $0 { true } else { false } })
    }

    /// The row's cloud mark is the only sign: it never names the machine, on a line or to VoiceOver.
    @Test func aCloudRowHasACloudMarkAndNeverItsMachinesName() throws {
        let rows = layout(sections).rows
        let row = try #require(rows.first { $0.key == .workspace(WorkspaceID("ws_a")) })
        let content = try #require(row.content)
        #expect(content.runsInCloud)
        #expect(content.machine == nil && content.machineLabel == nil && content.meta?.contains("lease") != true)
        let label = WorkspaceRowView.accessibilityText(SidebarWorkspace(id: WorkspaceID("ws_a"), machineID: MachineID("lease-lease_21_c6c"), title: "Fix login"),
                                                       content: content, tabCount: nil, presence: [])
        #expect(label.contains(Strings.hoverCloud) && !label.contains("lease"))
        let local = try #require(rows.first { $0.key == .workspace(WorkspaceID("ws_mac")) }?.content)
        #expect(!local.runsInCloud)
    }

    /// Leo 2026-11-22: "im not sure we want the cloud icon at the left. it makes it stick out in a slight eyesore-y
    /// way. compared to the local ones which have no icon." The leading slot is state only: a Cloud row with no icon
    /// of its own starts its title where a local row's does, and its small cloud sits in the trailing status cluster.
    @Test func theCloudMarkSitsTrailingAndTheTitleStartsWhereALocalRowsDoes() throws {
        let rows = layout(sections).rows
        func view(_ id: String, machine: String) throws -> WorkspaceRowView {
            let row = try #require(rows.first { $0.key == .workspace(WorkspaceID(id)) })
            let view = WorkspaceRowView(key: row.key)
            view.frame = NSRect(x: 0, y: 0, width: 240, height: row.height)
            view.configure(SidebarWorkspace(id: WorkspaceID(id), machineID: MachineID(machine), title: "Fix login"), row: row)
            view.layoutSubtreeIfNeeded()
            return view
        }
        let cloud = try view("ws_a", machine: "lease-lease_21_c6c"), local = try view("ws_mac", machine: "local")
        #expect(!cloud.cloudMark.isHidden && local.cloudMark.isHidden)
        #expect(abs(cloud.title.frame.minX - local.title.frame.minX) < 0.5, "a Cloud row's title moved for a leading cloud")
        #expect(cloud.cloudMark.frame.minX > 240 / 2 && cloud.cloudMark.frame.maxX <= 240, "the cloud is not in the trailing cluster")
    }
}
