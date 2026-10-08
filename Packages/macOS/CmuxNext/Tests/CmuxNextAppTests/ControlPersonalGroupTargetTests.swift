import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// cx-qno.17 (live capture on cmux-lawrence-2): every `workspace-group:<id>`
/// target from the socket and CLI failed with not_found, because the control
/// topology listed only the daemon's shared groups while the sidebar shows
/// the home session's personal groups. The topology lists the groups the
/// sidebar draws, so `cmux workspace-group rename/collapse/...` reach them.
@MainActor @Suite struct ControlPersonalGroupTargetTests {
    @Test func theTopologyListsPersonalGroups() {
        let store = DaemonStore()
        store.applyPersonal(PersonalState(groups: [
            WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "grp_frontend"), name: "Frontend", color: "blue", collapsed: true),
        ]))
        let topology = ControlTopologyMapper.topology(store: store, selectedTab: { _ in nil })
        let group = topology.workspaceGroups.first { $0.id == "grp_frontend" }
        #expect(group != nil, "personal groups are targets")
        #expect(group?.name == "Frontend")
        #expect(group?.isCollapsed == true)
    }
}
