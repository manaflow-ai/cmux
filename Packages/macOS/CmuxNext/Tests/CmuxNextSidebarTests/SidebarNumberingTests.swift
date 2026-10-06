@testable import CmuxNextSidebar
import Testing

/// R119 + TOP-SECTION-ITEMS-ARE-PAGES: Cmd+1 is the first top-section item
/// (Home by default; it opens Home's page), then the workspaces in sidebar
/// order; Cmd+9 is the last. With no top item the workspaces start at 1.
struct SidebarNumberingTests {
    static let home = LayoutItemID("itm_home")

    /// The numbering with Home as the first top item, written as strings.
    static func order(_ workspaces: [String], first: LayoutItemID? = home) -> [String] {
        SidebarNumbering(firstTopItem: first, workspaces: workspaces).order.map(name)
    }

    static func pick(_ number: Int, _ workspaces: [String], first: LayoutItemID? = home) -> String? {
        SidebarNumbering(firstTopItem: first, workspaces: workspaces).pick(number).map(name)
    }

    static func name(_ target: SidebarNumbering.Target) -> String {
        switch target {
        case .topItem(let item): "item:" + item.rawValue
        case .workspace(let id): id
        }
    }

    @Test func theFirstTopItemIsOneThenWorkspacesInOrder() {
        #expect(Self.order(["a", "b", "c"]) == ["item:itm_home", "a", "b", "c"])
        #expect(SidebarNumbering(firstTopItem: Self.home, workspaces: ["a"]).pick(1) == .topItem(Self.home))
        #expect(Self.pick(2, ["a", "b", "c"]) == "a")
        #expect(Self.pick(4, ["a", "b", "c"]) == "c")
    }

    @Test func nineIsLastAndPastTheEndClamps() {
        #expect(Self.pick(9, ["a", "b"]) == "b")
        #expect(Self.pick(6, ["a", "b"]) == "b")
        #expect(Self.pick(9, []) == "item:itm_home")
    }

    @Test func noTopItemStartsAtTheFirstWorkspace() {
        #expect(Self.pick(1, ["a", "b"], first: nil) == "a")
        #expect(Self.pick(1, [], first: nil) == nil)
        #expect(Self.pick(0, ["a"]) == nil)
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
        #expect(Self.order(model.visibleWorkspaceIDs) == ["item:itm_home", "p1", "w1", "w2", "w3", "c1"])
        #expect(Self.pick(9, model.visibleWorkspaceIDs) == "c1")
    }

    /// Rows the user cannot see get no number: a collapsed section, a
    /// collapsed group, rows the sidebar filter hides. Cmd+9 is the last visible.
    @MainActor @Test func hiddenRowsAreNotNumbered() {
        #expect(Self.model(collapsedCloud: true).visibleWorkspaceIDs == ["p1", "w1", "w2", "w3"])
        #expect(Self.model(collapsedGroup: true).visibleWorkspaceIDs == ["p1", "w1", "c1"])
        let filtered = Self.model()
        filtered.filterText = "w"
        #expect(filtered.visibleWorkspaceIDs == ["w1", "w2", "w3"])
        #expect(Self.pick(9, filtered.visibleWorkspaceIDs) == "w3")
    }
}
