@testable import CmuxNextSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/25776: Cmd-Shift-N opened a window whose sidebar listed every group
/// of the other windows, each empty ("No workspaces · drag one here"). As in cmux classic, a group belongs to the
/// window that lists its workspaces: a new window shows only its own. A group with no open workspace anywhere (an
/// empty group, a saved group whose members closed) belongs to no window and still lists everywhere.
@MainActor @Suite struct SidebarNewWindowGroupsTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let custom = "sec_custom"
    static let pinned = "sec_pinned"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    static func groupItem(_ id: String, _ section: String, parent: String? = nil) -> SidebarDocItem {
        SidebarDocItem(id: id, section: section, parent: parent, body: .group(name: id, color: nil, icon: nil, collapsed: false))
    }

    /// A custom section with group `itm_ga` (open member `ws-2`) and `itm_gp`, whose subgroup `itm_gk` holds open
    /// `ws-3`; Pinned with saved group `itm_gs`, whose one member `ws-4` is closed (a dimmed row). This Mac: `ws-1`.
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            custom: SidebarDocSection(id: custom, kind: .custom, title: "Work"),
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_ga": groupItem("itm_ga", custom),
            "itm_2": SidebarDocItem(id: "itm_2", section: custom, parent: "itm_ga", body: .workspace(ref("ws-2"))),
            "itm_gp": groupItem("itm_gp", custom),
            "itm_gk": groupItem("itm_gk", custom, parent: "itm_gp"),
            "itm_3": SidebarDocItem(id: "itm_3", section: custom, parent: "itm_gk", body: .workspace(ref("ws-3"))),
            "itm_gs": groupItem("itm_gs", pinned),
            "itm_4": SidebarDocItem(id: "itm_4", section: pinned, parent: "itm_gs", body: .workspace(ref("ws-4"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gs", kind: "group", section: pinned, item: "itm_gs"),
            SidebarDocRow(key: "itm_4", kind: "item", section: pinned, parent: "itm_gs", depth: 1, item: "itm_4", dimmed: true, ref: ref("ws-4")),
            SidebarDocRow(key: "itm_ga", kind: "group", section: custom, item: "itm_ga"),
            SidebarDocRow(key: "itm_2", kind: "item", section: custom, parent: "itm_ga", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_gp", kind: "group", section: custom, item: "itm_gp"),
            SidebarDocRow(key: "itm_gk", kind: "group", section: custom, parent: "itm_gp", depth: 1, item: "itm_gk"),
            SidebarDocRow(key: "itm_3", kind: "item", section: custom, parent: "itm_gk", depth: 2, item: "itm_3", ref: ref("ws-3")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    static let thisMac = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func groupIDs(_ sections: [SidebarSection]) -> [String] {
        sections.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } }
    }

    /// The new window lists `ws-1` alone; the other window lists `ws-2` and `ws-3`, so their groups are its own.
    @Test func aNewWindowListsNoGroupOfAnotherWindow() {
        let newWindow = [SidebarSection(kind: .machine(Self.thisMac), nodes: [.workspace(Self.ws("ws-1"))])]
        let arranged = Self.projection().arrange(newWindow, drag: Self.drag)
        #expect(Self.groupIDs(arranged) == ["itm_gs"], "groups listed: \(Self.groupIDs(arranged))")
    }

    /// An open member no other window lists (its close runs, or its window's row is on the way) keeps the group's
    /// header here, as a closed one does: a saved group never blinks out while its last workspace closes.
    @Test func aGroupWhoseOpenMemberNoOtherWindowListsKeepsItsHeader() {
        var drag = Self.drag
        drag.listedElsewhere = { $0.workspaceID == "ws-3" }
        let window = [SidebarSection(kind: .machine(Self.thisMac), nodes: [.workspace(Self.ws("ws-1"))])]
        let arranged = Self.projection().arrange(window, drag: drag)
        #expect(Set(Self.groupIDs(arranged)) == ["itm_gs", "itm_ga"], "groups listed: \(Self.groupIDs(arranged))")
    }

    /// The window that lists the members keeps every group, the parent of a subgroup with a member too.
    @Test func theOwningWindowKeepsItsGroups() {
        let owner = [SidebarSection(kind: .machine(Self.thisMac), nodes: [
            .group(SidebarGroup(id: GroupID("itm_ga"), name: "itm_ga", workspaces: [Self.ws("ws-2")])),
            .group(SidebarGroup(id: GroupID("itm_gp"), name: "itm_gp", workspaces: [])),
            .group({ var g = SidebarGroup(id: GroupID("itm_gk"), name: "itm_gk", workspaces: [Self.ws("ws-3")]); g.parent = GroupID("itm_gp"); return g }()),
        ])]
        let arranged = Self.projection().arrange(owner, drag: Self.drag)
        #expect(Set(Self.groupIDs(arranged)) == ["itm_gs", "itm_ga", "itm_gp", "itm_gk"], "groups listed: \(Self.groupIDs(arranged))")
    }

    /// The window filter (every path, also without the sidebar document): a group whose workspaces another window
    /// lists leaves this window with its subgroups' parent and its link members; an empty group and this window's stay.
    @Test func theWindowFilterDropsGroupsWhoseWorkspacesListElsewhere() {
        func group(_ id: String, _ members: [String], parent: String? = nil) -> SidebarGroup {
            var group = SidebarGroup(id: GroupID(id), name: id, workspaces: members.map(Self.ws))
            group.parent = parent.map(GroupID.init)
            return group
        }
        var linked = group("linked", ["ws-4"])
        linked.items = [SidebarGroupItem(item: SidebarListItem(id: "link", ref: .url("https://example.com"), title: "Example"))]
        var onlyLinks = group("only-links", [])
        onlyLinks.items = linked.items
        let session = [SidebarSection(kind: .machine(Self.thisMac), nodes: [
            .workspace(Self.ws("ws-1")),
            .group(group("elsewhere", ["ws-2"])),
            .group(group("parent", [])),
            .group(group("child", ["ws-3"], parent: "parent")),
            .group(linked),
            .group(onlyLinks),
            .group(group("empty", [])),
            .group(group("mine-parent", [])),
            .group(group("mine", ["ws-5", "ws-6"], parent: "mine-parent")),
        ])]
        let filtered = SidebarSection.filter(session, members: ["ws-1", "ws-5"])
        #expect(Self.groupIDs(filtered) == ["only-links", "empty", "mine-parent", "mine"], "groups listed: \(Self.groupIDs(filtered))")
        #expect(filtered.flatMap(\.workspaces).map(\.id.rawValue) == ["ws-1", "ws-5"])
    }
}
