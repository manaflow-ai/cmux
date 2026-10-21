import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Nested groups draw (remote-groups-DESIGN.md slice 2): a subgroup is its own header under its
/// parent, one level further in (`SidebarRow.depth`), its members one level further still; a
/// collapsed group hides its whole subtree; a filter keeps the path of groups down to a match.
@MainActor struct SidebarNestedGroupLayoutTests {
    private let project = GroupID("g_project"), branch = GroupID("g_branch"), leaf = GroupID("g_leaf")

    private func sections(collapsed: Set<GroupID> = []) -> [SidebarSection] {
        let machine = SidebarMachine(id: MachineID("mini"), name: "mini", kind: .server)
        func group(_ id: GroupID, parent: GroupID?, depth: Int, _ members: [String]) -> SidebarNode {
            var made = SidebarGroup(id: id, name: id.rawValue, isCollapsed: collapsed.contains(id),
                                    workspaces: members.map { SidebarWorkspace(id: WorkspaceID($0), title: $0) })
            made.parent = parent
            made.depth = depth
            return .group(made)
        }
        return [SidebarSection(kind: .machine(machine), nodes: [
            group(project, parent: nil, depth: 0, ["a2"]),
            group(branch, parent: project, depth: 1, []),
            group(leaf, parent: branch, depth: 2, ["a1"]),
            .workspace(SidebarWorkspace(id: WorkspaceID("a3"), title: "a3")),
        ])]
    }

    private func rows(_ sections: [SidebarSection], filter: Set<WorkspaceID>? = nil) -> [SidebarRow] {
        var options = SidebarLayoutOptions()
        options.filterMatches = filter
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows
    }

    private func depth(_ rows: [SidebarRow], _ key: SidebarRowKey) -> Int? { rows.first { $0.key == key }?.depth }

    @Test func subgroupsIndentOneLevelPerAncestor() {
        let rows = rows(sections())
        #expect(depth(rows, .group(project)) == 0)
        #expect(depth(rows, .workspace(WorkspaceID("a2"))) == 1)
        #expect(depth(rows, .group(branch)) == 1)
        #expect(depth(rows, .group(leaf)) == 2)
        #expect(depth(rows, .workspace(WorkspaceID("a1"))) == 3)
        #expect(depth(rows, .workspace(WorkspaceID("a3"))) == 0)
        let order = rows.map(\.key)
        let at = { (key: SidebarRowKey) in order.firstIndex(of: key) ?? -1 }
        #expect(at(.group(project)) < at(.group(branch)) && at(.group(branch)) < at(.group(leaf)))
        #expect(rows.first { $0.key == .workspace(WorkspaceID("a1")) }?.group == leaf)
    }

    @Test func aCollapsedGroupHidesItsWholeSubtree() {
        let rows = rows(sections(collapsed: [branch]))
        #expect(rows.contains { $0.key == .group(branch) && $0.isCollapsed })
        #expect(!rows.contains { $0.key == .group(leaf) })
        #expect(!rows.contains { $0.key == .workspace(WorkspaceID("a1")) })
        #expect(rows.contains { $0.key == .workspace(WorkspaceID("a2")) }, "the parent's own member stays")
    }

    @Test func aFilterKeepsThePathToADeepMatch() {
        let rows = rows(sections(), filter: [WorkspaceID("a1")])
        for key in [SidebarRowKey.group(project), .group(branch), .group(leaf), .workspace(WorkspaceID("a1"))] {
            #expect(rows.contains { $0.key == key }, "\(key) shows")
        }
        #expect(!rows.contains { $0.key == .workspace(WorkspaceID("a2")) })
    }

    /// The fast fold (`SidebarLayout.folding`, a group's own rows spliced) gives the same rows as a
    /// full layout, nested groups too: folding a project hides its branch and leaf, and opening it
    /// shows them again at their depth.
    @Test func foldingAParentGivesTheSameRowsAsAFullLayout() {
        let open = SidebarLayout.make(sections: sections(), metrics: .standard)
        let closed = SidebarLayout.make(sections: sections(collapsed: [project]), metrics: .standard)
        guard case let .group(projectGroup)? = sections(collapsed: [project]).first?.nodes.first,
              let section = sections().first else {
            Issue.record("fixture")
            return
        }
        let folded = open.folding(projectGroup, collapsed: true, in: section, metrics: .standard, options: SidebarLayoutOptions()) ?? closed
        #expect(folded.rows == closed.rows)
        var opened = projectGroup
        opened.isCollapsed = false
        let unfolded = closed.folding(opened, collapsed: false, in: section, metrics: .standard, options: SidebarLayoutOptions()) ?? open
        #expect(unfolded.rows == open.rows)
    }

    /// A flat group's members carry depth 1 on both paths.
    @Test func aFlatGroupsMembersAreOneLevelInOnBothPaths() {
        let machine = SidebarMachine(id: MachineID("mini"), name: "mini", kind: .server)
        let group = SidebarGroup(id: GroupID("flat"), name: "flat", workspaces: [SidebarWorkspace(id: WorkspaceID("w"), title: "w")])
        var collapsed = group
        collapsed.isCollapsed = true
        let section = SidebarSection(kind: .machine(machine), nodes: [.group(group)])
        let closed = SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: [.group(collapsed)])], metrics: .standard)
        let open = SidebarLayout.make(sections: [section], metrics: .standard)
        let unfolded = closed.folding(group, collapsed: false, in: section, metrics: .standard, options: SidebarLayoutOptions()) ?? open
        #expect(unfolded.rows == open.rows)
        #expect(open.rows.first { $0.key == .workspace(WorkspaceID("w")) }?.depth == 1)
    }
}
