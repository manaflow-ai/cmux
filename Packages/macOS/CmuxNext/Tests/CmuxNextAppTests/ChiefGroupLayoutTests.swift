import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Chief's subagent workspaces are one collapsible "Chief" group in the one-list sidebar (Leo
/// 2026-10-21), not loose rows that read as members of the last group above them. The local Chief
/// machine's section keeps its header and fold there, as a remote group does; another computer's
/// section still draws none.
@MainActor struct ChiefGroupLayoutTests {
    static let chiefID = MachineID("server-host_chief6b68ac4a")

    private func sections(chiefCollapsed: Bool = false) -> [SidebarSection] {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("codex"), name: "Codex", isCollapsed: true,
                                workspaces: [SidebarWorkspace(id: WorkspaceID("codex-ws"), title: "codex ws")])),
        ])
        let chief = SidebarSection(kind: .machine(SidebarMachine(id: Self.chiefID, name: "Chief", kind: .server)),
                                   isCollapsed: chiefCollapsed,
                                   nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("a14"), machineID: Self.chiefID,
                                                                       title: "Native workflows runtime"))])
        let vm = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("vm-1"), name: "vm", kind: .ssh)),
                                nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("vm-ws"), title: "vm ws"))])
        return [local, chief, vm]
    }

    private func layout(_ sections: [SidebarSection]) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    private func keys(_ layout: SidebarLayout) -> [SidebarRowKey] { layout.rows.map(\.key) }

    @Test func theChiefsWorkspacesSitUnderTheirOwnHeaderInOneList() {
        let rows = keys(layout(sections()))
        let header = SidebarRowKey.section(.machine(Self.chiefID))
        #expect(rows.contains(header))
        let at = rows.firstIndex(of: header)!
        #expect(rows.firstIndex(of: .workspace(WorkspaceID("a14")))! == at + 1, "the Chief's rows follow its header")
        // Another computer in one list still has no header.
        #expect(!rows.contains(.section(.machine(MachineID("vm-1")))))
        #expect(!rows.contains(.section(.machine(.local))))
    }

    @Test func theChiefGroupFolds() {
        let rows = keys(layout(sections(chiefCollapsed: true)))
        #expect(rows.contains(.section(.machine(Self.chiefID))))
        #expect(!rows.contains(.workspace(WorkspaceID("a14"))))
        let header = layout(sections(chiefCollapsed: true)).rows.first { $0.key == .section(.machine(Self.chiefID)) }
        #expect(header?.isCollapsed == true)
    }

    @Test func anEmptyChiefDrawsNothing() {
        var all = sections()
        all[1].nodes = []
        let rows = keys(layout(all))
        #expect(!rows.contains(.section(.machine(Self.chiefID))))
        #expect(!rows.contains(.emptySection(.machine(Self.chiefID))))
    }

    @Test func aComputerAfterTheChiefGroupIsSetApart() {
        // The next headerless computer's rows are not drawn as the Chief group's members: a section gap.
        let made = layout(sections())
        let chiefRow = made.rows.first { $0.key == .workspace(WorkspaceID("a14")) }!
        let vmRow = made.rows.first { $0.key == .workspace(WorkspaceID("vm-ws")) }!
        let metrics = SidebarLayoutMetrics.standard
        #expect(vmRow.y >= chiefRow.y + chiefRow.height + metrics.rowSpacing + metrics.sectionSpacing - 0.5)
    }

    @Test func theRuleIsOneFunctionForEveryHeaderKind() {
        let all = sections()
        #expect(SidebarLayout.keepsHeaderInOneList(all[1]))
        #expect(!SidebarLayout.keepsHeaderInOneList(all[0]))
        #expect(!SidebarLayout.keepsHeaderInOneList(all[2]))
        var host = all[2]
        host.isHostGroup = true
        #expect(SidebarLayout.keepsHeaderInOneList(host))
    }
}
