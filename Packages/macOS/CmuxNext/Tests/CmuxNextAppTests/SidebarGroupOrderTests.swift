import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Group ordering verbs (plans/cmux-next/sidebar-ordering-AUDIT.md, Lawrence 2026-10-19: "I need
/// an option to move a group to the top"). `SidebarEdits.groupIndex` gives the section-row index
/// `.reorderGroup` takes. Before it, Move Group Up/Down passed the group's index among the room's
/// groups, while the intent counts every row of the section: with loose rows above the groups,
/// Move Down sent the first group up among the loose rows and Move Up sent the second group to the
/// very top.
@Suite struct SidebarGroupOrderTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g1 = GroupID("g1"), g2 = GroupID("g2")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`, `b`; group `g1` (`c`); group `g2` (`d`, `e`, collapsed); loose `f`.
    static func sections(g2Collapsed: Bool = true, g1Collapsed: Bool = false) -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("a")), .workspace(row("b")),
            .group(SidebarGroup(id: g1, name: "one", isCollapsed: g1Collapsed, workspaces: [row("c")])),
            .group(SidebarGroup(id: g2, name: "two", isCollapsed: g2Collapsed, workspaces: [row("d"), row("e")])),
            .workspace(row("f")),
        ])]
    }

    static func order(_ sections: [SidebarSection]) -> [String] {
        sections[0].nodes.map { node in
            switch node {
            case let .workspace(ws): ws.id.rawValue
            case let .group(group): group.id.rawValue
            case let .item(item): item.id
            }
        }
    }

    /// Move Group to Top through the app's call: the index the shared rule gives, applied by the shared edit,
    /// with every row kept as it was. The ordering rules' cases are the Rust tests (cmux-layout-reducer
    /// `sidebar_edits::tests`).
    @Test func moveToTopThroughTheSharedRules() throws {
        var sections = Self.sections()
        let index = try #require(SidebarEdits.groupIndex(Self.g2, .top, in: sections))
        #expect(SidebarEdits.apply(.reorderGroup(Self.g2, index: index), to: &sections))
        #expect(Self.order(sections) == ["g2", "a", "b", "g1", "f"])
        #expect(sections[0].nodes.first.flatMap { if case let .group(group) = $0 { group.isCollapsed } else { nil } } == true)
        #expect(SidebarEdits.groupIndex(Self.g2, .top, in: sections) == nil)
        #expect(SidebarEdits.groupsToggledByCollapsingOthers(keeping: Self.g1, in: Self.sections(g2Collapsed: false)) == [Self.g2])
    }

    /// A multi-selection moved to the top of its group lands there as one block, in sidebar order.
    @Test func selectionMovesToTheTopOfItsGroupAsOneBlock() throws {
        // Group `g2` holds `d`, `e`, `x`; the selection is `x` and `e`, right-clicked on `x`.
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.row("a")),
            .group(SidebarGroup(id: Self.g2, name: "two", workspaces: [Self.row("d"), Self.row("e"), Self.row("x")])),
        ])]
        let moving = SidebarEdits.treeOrder([WorkspaceID("x"), WorkspaceID("e")], in: sections)
        #expect(moving.map(\.rawValue) == ["e", "x"], "the block keeps sidebar order")
        let position = try #require(WorkspaceSlot.top(anchor: "x").position(moving: ["x", "e"], section: .machine(.local), in: sections))
        #expect(position.group == Self.g2 && position.index == 0)
        #expect(SidebarEdits.apply(.reorder(moving, to: position), to: &sections))
        let members = sections[0].nodes.compactMap { node -> [String]? in
            if case let .group(group) = node, group.id == Self.g2 { group.workspaces.map(\.id.rawValue) } else { nil }
        }.first
        #expect(members == ["e", "x", "d"])
    }
}
