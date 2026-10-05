@testable import CmuxNextSidebar
import Testing

/// R119: Cmd+1…9 numbers Home first, then the workspaces in sidebar order;
/// Cmd+9 is the last. Home is never numbered twice, and with no Home yet
/// the workspaces start at 1.
struct SidebarNumberingTests {
    @Test func homeIsOneThenWorkspacesInOrder() {
        let order = SidebarNumbering.order(home: "home", workspaces: ["a", "b", "c"])
        #expect(order == ["home", "a", "b", "c"])
        #expect(SidebarNumbering.pick(1, home: "home", workspaces: ["a", "b", "c"]) == "home")
        #expect(SidebarNumbering.pick(2, home: "home", workspaces: ["a", "b", "c"]) == "a")
        #expect(SidebarNumbering.pick(4, home: "home", workspaces: ["a", "b", "c"]) == "c")
    }

    @Test func nineIsLastAndPastTheEndClamps() {
        #expect(SidebarNumbering.pick(9, home: "home", workspaces: ["a", "b"]) == "b")
        #expect(SidebarNumbering.pick(6, home: "home", workspaces: ["a", "b"]) == "b")
        #expect(SidebarNumbering.pick(9, home: "home", workspaces: []) == "home")
    }

    @Test func homeListedAmongWorkspacesIsNotNumberedTwice() {
        #expect(SidebarNumbering.order(home: "home", workspaces: ["a", "home", "b"]) == ["home", "a", "b"])
    }

    @Test func noHomeStartsAtTheFirstWorkspace() {
        #expect(SidebarNumbering.pick(1, home: nil, workspaces: ["a", "b"]) == "a")
        #expect(SidebarNumbering.pick(1, home: nil, workspaces: []) == nil)
        #expect(SidebarNumbering.pick(0, home: "home", workspaces: ["a"]) == nil)
    }

    /// Numbers follow the rows top to bottom: pinned, then each machine
    /// section, workspaces inside a group in place, placeholders skipped.
    @MainActor @Test func numberingFollowsTheSidebarRowOrderAcrossSections() {
        func ws(_ id: String, machine: MachineID = .local, state: SidebarRowState = .live) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id, rowState: state)
        }
        let cloud = MachineID("cloud")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(ws("p1"))]),
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [
                .workspace(ws("w1")),
                .group(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [ws("w2"), ws("w3")])),
                .workspace(ws("w4", state: .placeholder)),
            ]),
            SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud)), nodes: [.workspace(ws("c1", machine: cloud))]),
        ])
        let order = SidebarNumbering.order(home: "home", workspaces: model.selectableWorkspaces.map(\.id.rawValue))
        #expect(order == ["home", "p1", "w1", "w2", "w3", "c1"])
        #expect(SidebarNumbering.pick(7, home: "home", workspaces: model.selectableWorkspaces.map(\.id.rawValue)) == "c1")
    }
}
