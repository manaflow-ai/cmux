import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Nested workspace groups in the sidebar (`workspace-group-nest-v1`): a group
/// may sit in a group, three levels deep. The document's rows come depth
/// first; each nested group is its own node after its parent's, and the list
/// draws it under its parent's header, one gutter in per level. Collapsing a
/// parent hides every level under it (each child keeps its own collapse), and
/// a collapsed header counts the workspaces of every level.
@MainActor @Suite struct SidebarNestedGroupsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func row(_ id: String, unread: UnreadState = .none) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: id, unread: unread)
    }

    /// `top` (member `a`) holds `middle` (member `b`), which holds `inner` (member `c`); `loose` follows.
    static func nodes(topCollapsed: Bool = false, middleCollapsed: Bool = false, unread: Bool = false) -> [SidebarNode] {
        [
            .group(SidebarGroup(id: GroupID("top"), name: "Top", isCollapsed: topCollapsed, workspaces: [row("a")])),
            .group(SidebarGroup(id: GroupID("middle"), name: "Middle", isCollapsed: middleCollapsed, parent: GroupID("top"),
                                workspaces: [row("b")])),
            .group(SidebarGroup(id: GroupID("inner"), name: "Inner", parent: GroupID("middle"),
                                workspaces: [row("c", unread: unread ? .count(2) : .none)])),
            .workspace(row("loose")),
        ].fillingNestedWorkspaces()
    }

    static func layout(_ nodes: [SidebarNode], filter: Set<String>? = nil, active: String? = nil) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.filterMatches = filter.map { Set($0.map(WorkspaceID.init)) }
        options.activeWorkspaceID = active.map(WorkspaceID.init)
        return SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], metrics: .standard, options: options)
    }

    /// The group and workspace rows in order, with their nesting level.
    static func listed(_ layout: SidebarLayout) -> [String] {
        layout.rows.compactMap { row in
            switch row.key {
            case let .group(id): "\(id.rawValue)@\(row.depth)"
            case let .workspace(id): "\(id.rawValue)@\(row.depth)"
            default: nil
            }
        }
    }

    @Test func nestedGroupsListUnderTheirParentOneLevelInEach() {
        let layout = Self.layout(Self.nodes())
        // Inside a parent its nested groups come first, then its own workspaces.
        #expect(Self.listed(layout) == ["top@0", "middle@1", "inner@2", "c@3", "b@2", "a@1", "loose@0"])
        #expect(layout.row(for: .group(GroupID("inner")))?.parentGroup == GroupID("middle"))
        #expect(layout.row(for: .group(GroupID("top")))?.parentGroup == nil)
        #expect(layout.row(for: .workspace(WorkspaceID("c")))?.group == GroupID("inner"))
    }

    @Test func collapsingAParentHidesEveryLevelAndCountsTheirWorkspaces() {
        let layout = Self.layout(Self.nodes(topCollapsed: true))
        #expect(Self.listed(layout) == ["top@0", "loose@0"])
        #expect(layout.row(for: .group(GroupID("top")))?.childCount == 3, "a collapsed header counts a, b and c")
    }

    @Test func aChildKeepsItsOwnCollapseUnderAnOpenParent() {
        let layout = Self.layout(Self.nodes(middleCollapsed: true))
        #expect(Self.listed(layout) == ["top@0", "middle@1", "a@1", "loose@0"])
        #expect(layout.row(for: .group(GroupID("middle")))?.childCount == 2)
    }

    @Test func aCollapsedParentStillShowsTheSelectedWorkspaceOfANestedGroup() {
        let layout = Self.layout(Self.nodes(topCollapsed: true), active: "c")
        #expect(Self.listed(layout) == ["top@0", "c@1", "loose@0"])
        #expect(layout.row(for: .workspace(WorkspaceID("c")))?.group == GroupID("inner"), "it stays a member of its own group")
    }

    @Test func aFilterKeepsTheGroupsAboveAMatch() {
        let layout = Self.layout(Self.nodes(), filter: ["c"])
        #expect(Self.listed(layout) == ["top@0", "middle@1", "inner@2", "c@3"])
    }

    @Test func aParentHeaderCountsTheUnreadOfItsNestedGroups() throws {
        let top = try #require(Self.nodes(unread: true).compactMap { node -> SidebarGroup? in
            if case let .group(group) = node, group.id == GroupID("top") { group } else { nil }
        }.first)
        #expect(top.unreadTotal == 2)
        #expect(top.nestedWorkspaces.map(\.id.rawValue) == ["b", "c"])
    }

    @Test func theDocumentRowsOfANestBecomeOneNodePerGroup() throws {
        let section = "sec_m_s"
        let ref = { (id: String) in SidebarDocWorkspaceRef(sessionID: "s", workspaceID: id) }
        var records = SidebarDocRecords(sections: [section: SidebarDocSection(id: section, kind: .machine(session: "s"))])
        for (id, parent) in [("g_top", nil), ("g_mid", "g_top")] as [(String, String?)] {
            records.items[id] = SidebarDocItem(id: id, section: section, parent: parent,
                                               body: .group(name: id, color: nil, icon: nil, collapsed: false))
        }
        records.items["w_b"] = SidebarDocItem(id: "w_b", section: section, parent: "g_mid", body: .workspace(ref("b")))
        records.items["w_a"] = SidebarDocItem(id: "w_a", section: section, parent: "g_top", body: .workspace(ref("a")))
        let rows = [
            SidebarDocRow(key: "g_top", kind: "group", section: section, item: "g_top"),
            SidebarDocRow(key: "g_mid", kind: "group", section: section, parent: "g_top", depth: 1, item: "g_mid"),
            SidebarDocRow(key: "w_b", kind: "workspace", section: section, parent: "g_mid", depth: 2, item: "w_b", ref: ref("b")),
            SidebarDocRow(key: "w_a", kind: "workspace", section: section, parent: "g_top", depth: 1, item: "w_a", ref: ref("a")),
        ]
        let projection = SidebarDocProjection(rows: rows, records: records, revision: 1)
        let groups = (projection.machines["s"] ?? []).compactMap { node -> SidebarDocProjection.Group? in
            if case let .group(group) = node { group } else { nil }
        }
        #expect(groups.map(\.id) == ["g_top", "g_mid"])
        #expect(groups.map(\.parent) == [nil, "g_top"])
        #expect(groups.map { $0.members.map(\.workspaceID) } == [["a"], ["b"]], "each workspace joins its own group, not the last one listed")
    }

    @Test func moveToTopInANestedGroupGoesToTheTopOfThatGroup() throws {
        var nodes = Self.nodes()
        if case var .group(inner) = nodes[2] {
            inner.workspaces.append(Self.row("d"))
            nodes[2] = .group(inner)
        }
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: nodes)]
        let position = try #require(WorkspaceSlot.top(anchor: "d").position(moving: ["d"], section: .machine(.local), in: sections))
        #expect(position.group == GroupID("inner") && position.index == 0)
        // A loose row's Move to Top counts top-level slots only.
        let loose = try #require(WorkspaceSlot.bottom(anchor: "loose").position(moving: [], section: .machine(.local), in: sections))
        #expect(loose == DropPosition(section: .machine(.local), index: 2), "after `top` and `loose`, not after the nested groups' nodes")
    }

    @Test func ungroupMovesItsGroupsAndWorkspacesUpIntoItsParent() {
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: Self.nodes())]
        #expect(SidebarEdits.apply(.ungroup(GroupID("middle")), to: &sections))
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: SidebarLayoutOptions())
        #expect(Self.listed(layout) == ["top@0", "inner@1", "c@2", "a@1", "b@1", "loose@0"])
    }

    @Test func closingAGroupClosesItsNestedGroups() {
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: Self.nodes())]
        #expect(SidebarEdits.apply(.closeGroup(GroupID("top")), to: &sections))
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: SidebarLayoutOptions())
        #expect(Self.listed(layout) == ["loose@0"])
    }
}
