import AppKit
@testable import CmuxNextSidebar
import Testing

/// A remote group is one sidebar group (user 2026-10-31, Chief msg 19277): the wrap, its undo, and the
/// intents its daemon takes for it.
@MainActor @Suite struct SidebarHostGroupTests {
    let machine = MachineID("ssh-box")
    var host: GroupID { SidebarGroup.hostGroupID(machine) }

    func section(collapsed: Bool = false) -> SidebarSection {
        var sub = SidebarGroup(id: GroupID("g-a"), name: "A", color: .blue, isCollapsed: false,
                               workspaces: [SidebarWorkspace(id: WorkspaceID("w-2"), title: "two")])
        sub.parent = nil
        var s = SidebarSection(kind: .machine(SidebarMachine(id: machine, name: "box", kind: .ssh)), isCollapsed: collapsed,
                               nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-1"), title: "one")), .group(sub)])
        s.isHostGroup = true
        return s
    }

    @Test func theSectionBecomesOneGroupHoldingItsRows() throws {
        let wrapped = section(collapsed: true).wrappedAsHostGroup()
        #expect(wrapped.drawsAsGroup)
        #expect(!wrapped.isCollapsed, "the group folds, not the section")
        guard case let .group(top) = wrapped.nodes[0], case let .group(sub) = wrapped.nodes[1] else { Issue.record("shape"); return }
        #expect(top.id == host && top.machine?.name == "box" && top.isCollapsed)
        #expect(top.workspaces.map(\.id) == [WorkspaceID("w-1")])
        #expect(sub.parent == host && sub.depth == 1)
        #expect(!SidebarLayout.keepsHeaderInOneList(wrapped))
        let back = wrapped.unwrappedHostGroup()
        #expect(back.nodes.map(\.id) == section().nodes.map(\.id))
        #expect(back.isCollapsed && !back.drawsAsGroup)
        #expect(wrapped.wrappedAsHostGroup().unwrappedHostGroup().nodes.map(\.id) == back.nodes.map(\.id), "never wrapped twice")
    }

    @Test func thisMacIsNeverAGroup() {
        var s = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        s.isHostGroup = true
        #expect(!s.wrappedAsHostGroup().drawsAsGroup)
    }

    @Test func groupIntentsGoToTheMachine() {
        let end: (MachineID) -> Int = { _ in 2 }
        #expect(SidebarIntent.toggleCollapse(.group(host)).resolvingHostGroup(end: end) == .toggleCollapse(.section(.machine(machine))))
        #expect(SidebarIntent.newWorkspace(machine: nil, group: host).resolvingHostGroup(end: end) == .newWorkspace(machine: machine, group: nil))
        #expect(SidebarIntent.move([WorkspaceID("w-9")], toGroup: host).resolvingHostGroup(end: end)
            == .reorder([WorkspaceID("w-9")], to: DropPosition(section: .machine(machine), group: nil, index: 2)))
        #expect(SidebarIntent.reorder([WorkspaceID("w-9")], to: DropPosition(section: .machine(machine), group: host, index: 1)).resolvingHostGroup(end: end)
            == .reorder([WorkspaceID("w-9")], to: DropPosition(section: .machine(machine), group: nil, index: 1)))
        for edit: SidebarIntent in [.renameGroup(host, "x"), .ungroup(host), .setGroupColor(host, .palette(.red)), .closeGroup(host), .reorderGroup(host, index: 0)] {
            #expect(edit.resolvingHostGroup(end: end) == nil, "\(edit)")
        }
        let plain = SidebarIntent.renameGroup(GroupID("g-a"), "x")
        #expect(plain.resolvingHostGroup(end: end) == plain)
    }
}

/// A right-click on a remote group shows its machine's menu, never the group menu (rename, color, ungroup).
@MainActor @Suite struct SidebarHostGroupMenuTests {
    @Test func aRemoteGroupsMenuIsItsMachines() throws {
        let machine = MachineID("ssh-box")
        var s = SidebarSection(kind: .machine(SidebarMachine(id: machine, name: "box", kind: .ssh)),
                               nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w-1"), title: "one"))])
        s.isHostGroup = true
        let list = SidebarListView(model: SidebarModel(sections: [s.wrappedAsHostGroup()]))
        list.frame = CGRect(x: 0, y: 0, width: 280, height: 300)
        var asked: [SidebarContextTarget] = []
        list.contextMenuProvider = { asked.append($0); return NSMenu() }
        list.menuPresenter = { _, _, _ in }
        list.reload(animated: false)
        list.groupEditing.showMenu(SidebarGroup.hostGroupID(machine))
        list.groupEditing.open(SidebarGroup.hostGroupID(machine))
        #expect(asked == [.section(.machine(machine)), .section(.machine(machine))])
    }
}
