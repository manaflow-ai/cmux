import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// 2026-11-10, of a Cloud chat's workspace under a collapsible "lease-lease_21_c6c…" header with a chevron and a +: no
/// machine group, ever. A Cloud machine's workspaces are ordinary rows of the one list, with no cloud mark (cmux#55668: only a Cloud
/// chat's tab wears one), and the machine's name shows nowhere in the sidebar (no header, no row label). A remote group a person made
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

    /// cmux#55668 (2026-11-25): no cloud on any sidebar row; only a Cloud chat's tab wears it. A Cloud row never names its
    /// machine either, on a line or to VoiceOver: it draws exactly the views this Mac's row draws.
    @Test func aCloudRowHasNoCloudMarkAndNeverItsMachinesName() throws {
        let rows = layout(sections).rows
        let row = try #require(rows.first { $0.key == .workspace(WorkspaceID("ws_a")) })
        let content = try #require(row.content)
        #expect(content.machine == nil && content.machineLabel == nil && content.meta?.contains("lease") != true)
        let label = WorkspaceRowView.accessibilityText(SidebarWorkspace(id: WorkspaceID("ws_a"), machineID: MachineID("lease-lease_21_c6c"), title: "Fix login"),
                                                       content: content, tabCount: nil, presence: [])
        #expect(!label.contains(Strings.hoverCloud) && !label.contains("lease"), "\(label)")
        func view(_ id: String, machine: String) throws -> WorkspaceRowView {
            let row = try #require(rows.first { $0.key == .workspace(WorkspaceID(id)) })
            let view = WorkspaceRowView(key: row.key)
            view.frame = NSRect(x: 0, y: 0, width: 240, height: row.height)
            view.configure(SidebarWorkspace(id: WorkspaceID(id), machineID: MachineID(machine), title: "Fix login"), row: row)
            view.layoutSubtreeIfNeeded()
            return view
        }
        func shown(_ row: WorkspaceRowView) -> [String] {
            row.subviews.filter { !$0.isHidden && $0.alphaValue > 0 && !$0.frame.isEmpty }.map { String(describing: type(of: $0)) }.sorted()
        }
        let cloud = try view("ws_a", machine: "lease-lease_21_c6c"), local = try view("ws_mac", machine: "local")
        #expect(shown(cloud) == shown(local), "a Cloud row draws more than this Mac's row: \(shown(cloud)) vs \(shown(local))")
        #expect(abs(cloud.title.frame.minX - local.title.frame.minX) < 0.5)
    }
}
