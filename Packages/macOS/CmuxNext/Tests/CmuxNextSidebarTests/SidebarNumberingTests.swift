@testable import CmuxNextSidebar
import Testing

/// R119: Cmd+1…9 numbers Home first, then the workspaces in sidebar order;
/// Cmd+9 is the last. Home is never numbered twice, and with no Home yet
/// the workspaces start at 1.
struct SidebarNumberingTests {
    @Test func homeIsOneThenWorkspacesInOrder() {
        let order = SidebarNumbering(home: "home", workspaces: ["a", "b", "c"]).order
        #expect(order == ["home", "a", "b", "c"])
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "b", "c"]).pick(1) == "home")
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "b", "c"]).pick(2) == "a")
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "b", "c"]).pick(4) == "c")
    }

    @Test func nineIsLastAndPastTheEndClamps() {
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "b"]).pick(9) == "b")
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "b"]).pick(6) == "b")
        #expect(SidebarNumbering(home: "home", workspaces: []).pick(9) == "home")
    }

    @Test func homeListedAmongWorkspacesIsNotNumberedTwice() {
        #expect(SidebarNumbering(home: "home", workspaces: ["a", "home", "b"]).order == ["home", "a", "b"])
    }

    @Test func noHomeStartsAtTheFirstWorkspace() {
        #expect(SidebarNumbering(home: nil, workspaces: ["a", "b"]).pick(1) == "a")
        #expect(SidebarNumbering(home: nil, workspaces: []).pick(1) == nil)
        #expect(SidebarNumbering(home: "home", workspaces: ["a"]).pick(0) == nil)
    }

    static func ws(_ id: String, machine: MachineID = .local, state: SidebarRowState = .live) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id, rowState: state)
    }

    static let cloud = MachineID("cloud")

    @MainActor static func model(collapsedCloud: Bool = false, collapsedGroup: Bool = false) -> SidebarModel {
        SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(ws("p1"))]),
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [
                .workspace(ws("w1")),
                .group(SidebarGroup(id: GroupID("g"), name: "g", isCollapsed: collapsedGroup, workspaces: [ws("w2"), ws("w3")])),
                .workspace(ws("w4", state: .placeholder)),
            ]),
            SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud)), isCollapsed: collapsedCloud,
                           nodes: [.workspace(ws("c1", machine: cloud))]),
        ])
    }

    /// Numbers follow the visible rows top to bottom: pinned, then each
    /// machine section, workspaces inside a group in place, placeholders skipped.
    @MainActor @Test func numberingFollowsTheSidebarRowOrderAcrossSections() {
        let model = Self.model()
        #expect(SidebarNumbering(home: "home", workspaces: model.visibleWorkspaceIDs).order == ["home", "p1", "w1", "w2", "w3", "c1"])
        #expect(SidebarNumbering(home: "home", workspaces: model.visibleWorkspaceIDs).pick(9) == "c1")
    }

    /// Rows the user cannot see get no number: a collapsed section, a
    /// collapsed group, rows the sidebar filter hides. Cmd+9 is the last visible.
    @MainActor @Test func hiddenRowsAreNotNumbered() {
        #expect(Self.model(collapsedCloud: true).visibleWorkspaceIDs == ["p1", "w1", "w2", "w3"])
        #expect(Self.model(collapsedGroup: true).visibleWorkspaceIDs == ["p1", "w1", "c1"])
        let filtered = Self.model()
        filtered.filterText = "w"
        #expect(filtered.visibleWorkspaceIDs == ["w1", "w2", "w3"])
        #expect(SidebarNumbering(home: "home", workspaces: filtered.visibleWorkspaceIDs).pick(9) == "w3")
    }
}
