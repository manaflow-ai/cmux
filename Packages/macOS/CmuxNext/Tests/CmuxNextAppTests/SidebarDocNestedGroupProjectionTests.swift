import CmuxNextSidebar
import Testing

/// The sidebar document nests groups (remote-groups-DESIGN.md R1, host > project > branch), but the
/// sidebar list draws one level of groups until slice 2. Until then a nested tree draws as its
/// top-level group with every member of the tree, in document order: no workspace is dropped and
/// no nested group shows as a loose sibling group.
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

    @Test func aNestedTreeDrawsAsItsTopGroupWithEveryMember() throws {
        let nodes = try #require(projection().machines[session])
        let groups = nodes.compactMap { node -> SidebarDocProjection.Group? in
            if case let .group(group) = node { return group }
            return nil
        }
        #expect(groups.map(\.id) == ["g_project"], "nested groups are not loose siblings")
        #expect(groups.first?.members == [ref("a1"), ref("a2")], "the leaf's and the project's workspaces both show")
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
