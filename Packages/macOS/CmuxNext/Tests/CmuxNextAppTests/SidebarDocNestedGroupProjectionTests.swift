import CmuxNextSidebar
import Testing

/// The sidebar document nests groups (remote-groups-DESIGN.md R1, host > project > branch). The
/// projection lists each group of a tree as its own group node, in document order (a group before
/// its subgroups), with its parent and its depth (0 at the top level), and each group holds only
/// its own members. No workspace is dropped.
struct SidebarDocNestedGroupProjectionTests {
    private let session = "mini"
    private var section: String { "sec_m_\(session)" }

    private func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    private func group(_ id: String, parent: String?) -> SidebarDocItem {
        SidebarDocItem(id: id, section: section, parent: parent, body: .group(name: id, color: nil, icon: nil, collapsed: false))
    }

    private func workspace(_ id: String, parent: String?) -> SidebarDocItem {
        SidebarDocItem(id: "itm_w_\(session)_\(id)", section: section, parent: parent, body: .workspace(ref(id)))
    }

    /// project > branch > leaf(a1), and a2 directly in project after the branch: the rows the
    /// reducer's `view` returns for that tree.
    private func projection() -> SidebarDocProjection {
        let items = [
            group("g_project", parent: nil), group("g_branch", parent: "g_project"), group("g_leaf", parent: "g_branch"),
            workspace("a1", parent: "g_leaf"), workspace("a2", parent: "g_project"), workspace("a3", parent: nil),
        ]
        let depths = ["g_project": 0, "g_branch": 1, "g_leaf": 2, "itm_w_mini_a1": 3, "itm_w_mini_a2": 1, "itm_w_mini_a3": 0]
        let rows = items.map { item in
            SidebarDocRow(key: item.id, kind: item.body.workspace == nil ? "group" : "workspace", section: section, parent: item.parent,
                          depth: depths[item.id] ?? 0, item: item.id, ref: item.body.workspace)
        }
        let records = SidebarDocRecords(revision: 1, sections: [section: SidebarDocSection(id: section, kind: .machine(session: session))],
                                        items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }))
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    @Test func eachNestedGroupListsWithItsParentDepthAndOwnMembers() throws {
        let nodes = try #require(projection().machines[session])
        let groups = nodes.compactMap { node -> SidebarDocProjection.Group? in
            if case let .group(group) = node { return group }
            return nil
        }
        #expect(groups.map(\.id) == ["g_project", "g_branch", "g_leaf"], "a group before its subgroups")
        #expect(groups.map(\.parent) == [nil, "g_project", "g_branch"])
        #expect(groups.map(\.depth) == [0, 1, 2])
        #expect(groups.map(\.members) == [[ref("a2")], [], [ref("a1")]], "each group holds only its own members")
        let loose = nodes.compactMap { node -> SidebarDocWorkspaceRef? in
            if case let .workspace(ref, _) = node { return ref }
            return nil
        }
        #expect(loose == [ref("a3")])
    }

    @Test func everyPlacedWorkspaceKeepsItsItem() {
        let items = projection().items
        for id in ["a1", "a2", "a3"] {
            #expect(items[ref(id)] != nil, "\(id) is placed")
        }
    }
}
