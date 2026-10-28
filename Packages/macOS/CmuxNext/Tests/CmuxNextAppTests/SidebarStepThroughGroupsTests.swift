import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20 binds Next/Previous Sidebar Item (`nextSidebarTab` / `prevSidebarTab`) to ⌃⇥ / ⌃⇧⇥
/// and walks the whole sidebar with them. The walk visits every drawn row in order, the members of
/// an expanded group included, and a collapsed group is one stop (its members draw no row).
@MainActor @Suite(.serialized) struct SidebarStepThroughGroupsTests {
    private static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    private static func model() -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(row("loose-1")),
                .group(SidebarGroup(id: GroupID("open"), name: "Open", color: .red, isCollapsed: false,
                                    workspaces: [row("open-1"), row("open-2")])),
                .group(SidebarGroup(id: GroupID("shut"), name: "Shut", color: .green, isCollapsed: true,
                                    workspaces: [row("shut-1"), row("shut-2")])),
                .workspace(row("loose-2")),
            ]),
        ])
    }

    private static let rowsOnly = SidebarNavigationSettings(stepping: .workspacesOnly)

    @Test func theWalkVisitsEveryDrawnRowInOrder() {
        let order = Self.model().itemOrder
        #expect(order.rows == [.workspace(WorkspaceID("loose-1")), .workspace(WorkspaceID("open-1")), .workspace(WorkspaceID("open-2")),
                               .group(GroupID("shut")), .workspace(WorkspaceID("loose-2"))])
    }

    @Test func nextAndPreviousStepIntoAndOutOfAnExpandedGroup() {
        let order = Self.model().itemOrder
        #expect(order.step(from: .workspace(WorkspaceID("loose-1")), by: 1, Self.rowsOnly) == .workspace(WorkspaceID("open-1")))
        #expect(order.step(from: .workspace(WorkspaceID("open-2")), by: 1, Self.rowsOnly) == .group(GroupID("shut")))
        #expect(order.step(from: .workspace(WorkspaceID("open-1")), by: -1, Self.rowsOnly) == .workspace(WorkspaceID("loose-1")))
    }

    @Test func aCollapsedGroupIsOneStopAndItsMembersAreNot() {
        let order = Self.model().itemOrder
        // Shown from the collapsed group (its first member is the window's workspace), the walk goes on past it.
        #expect(order.step(from: .workspace(WorkspaceID("shut-1")), by: 1, Self.rowsOnly) == .workspace(WorkspaceID("loose-2")))
        #expect(order.step(from: .workspace(WorkspaceID("shut-2")), by: -1, Self.rowsOnly) == .workspace(WorkspaceID("open-2")))
        #expect(!order.rows.contains(.workspace(WorkspaceID("shut-1"))))
    }
}
