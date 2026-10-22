import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Show or hide remote groups (remote-groups-per-machine-DESIGN.md R2, `sidebar.showRemoteGroups`).
/// Hidden, a remote group draws no header and its workspaces join the one list with their machine
/// mark: nothing is removed and nothing disconnects. Shown (the default), each remote group is a
/// headed section again.
@MainActor struct RemoteGroupsVisibilityTests {
    private func section(_ name: String, kind: SidebarMachine.Kind, hostGroup: Bool) -> SidebarSection {
        var section = SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)),
                                     nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("\(name)-ws"), machineID: MachineID(name), title: name))])
        section.isHostGroup = hostGroup
        return section
    }

    private func layout(showsRemoteGroups: Bool) -> SidebarLayout {
        let sections = [section("local", kind: .local, hostGroup: false), section("cmux-mini-2", kind: .ssh, hostGroup: true)]
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        options.showsRemoteGroups = showsRemoteGroups
        options.machines = [MachineID("cmux-mini-2"): sections[1].machine!]
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    private func headers(_ layout: SidebarLayout) -> [SectionID] {
        layout.rows.compactMap { row in if case let .section(id) = row.key { id } else { nil } }
    }

    @Test func shownARemoteGroupKeepsItsHeader() {
        let shown = layout(showsRemoteGroups: true)
        #expect(headers(shown) == [.machine(MachineID("cmux-mini-2"))])
    }

    @Test func hiddenItsWorkspacesJoinTheOneListWithTheirMark() {
        let hidden = layout(showsRemoteGroups: false)
        #expect(headers(hidden).isEmpty)
        let row = hidden.row(for: .workspace(WorkspaceID("cmux-mini-2-ws")))
        #expect(row != nil, "hiding a remote group removes no workspace")
        #expect(row?.content?.machine?.kindIcon == .machineMac)
    }

    @Test func theSettingDefaultsToShownAndParses() {
        #expect(SidebarSectionsPreferences.defaults.showsRemoteGroups)
        let root: JSONValue = .object(["sidebar": .object(["showRemoteGroups": .bool(false)])])
        let off = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(off.sidebarSections.showsRemoteGroups == false)
        #expect(!off.diagnostics.contains { $0.path == "sidebar.showRemoteGroups" })
    }
}
