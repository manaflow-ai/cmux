import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar's tree edits are the shared Rust rules (cmux-layout-reducer `sidebar_edits`, whose tests hold the
/// cases). These check the Swift side of the call: the rows come back as they were, in their new places, with a
/// new group named and tinted from its intent and item rows kept.
@Suite struct SidebarEditsBridgeTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: "title \(id)") }

    static func ids(_ section: SidebarSection) -> [String] {
        section.nodes.map { node in
            switch node {
            case let .workspace(ws): ws.id.rawValue
            case let .group(group): group.id.rawValue
            case let .item(item): item.id
            }
        }
    }

    @Test func aReorderKeepsEveryRowsContentAndItsGroupsItems() throws {
        let link = SidebarListItem(id: "itm_link", ref: .builtIn(.chief), title: "Link")
        var group = SidebarGroup(id: GroupID("g"), name: "Group", isCollapsed: true, workspaces: [])
        group.setMembers([.workspace(Self.row("b")), .item(link), .workspace(Self.row("c"))])
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("a")), .group(group)])]
        #expect(SidebarEdits.apply(.reorder([WorkspaceID("b")], to: DropPosition(section: .machine(.local), index: 0)), to: &sections))
        #expect(Self.ids(sections[0]) == ["b", "a", "g"])
        #expect(sections[0].workspaces.map(\.title) == ["title b", "title a", "title c"])
        guard case let .group(moved) = sections[0].nodes[2] else { Issue.record("no group"); return }
        #expect(moved.name == "Group" && moved.isCollapsed)
        #expect(moved.members == [.item(link), .workspace(Self.row("c"))])
    }

    @Test func aNewGroupTakesItsNameAndTintFromTheIntent() throws {
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("a")), .workspace(Self.row("b"))])]
        let intent = SidebarIntent.createGroup(GroupID("n"), name: "Lanes", color: .palette(.blue), workspaces: [WorkspaceID("b")], collapsed: true)
        #expect(SidebarEdits.apply(intent, to: &sections))
        guard case let .group(made) = sections[0].nodes[1] else { Issue.record("no group"); return }
        #expect(made.name == "Lanes" && made.tint == .palette(.blue) && made.isCollapsed)
        #expect(made.workspaces.map(\.title) == ["title b"])
    }

    @Test func aPinAddsThePinnedSectionAndARefusedDropChangesNothing() {
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("a"))])]
        #expect(SidebarEdits.apply(.setPinned([WorkspaceID("a")], true), to: &sections))
        #expect(sections.map(\.id) == [.pinned, .machine(.local)])
        let before = sections
        #expect(!SidebarEdits.apply(.ungroup(GroupID("missing")), to: &sections))
        #expect(sections == before)
    }

    /// A closed parent's subgroup comes back at the top level, so a later pending edit does not treat it as nested
    /// under a group that is gone.
    @Test func aClosedParentsSubgroupComesBackAtTheTopLevel() {
        var sub = SidebarGroup(id: GroupID("s"), name: "Sub", workspaces: [Self.row("b")])
        sub.parent = GroupID("g")
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .group(SidebarGroup(id: GroupID("g"), name: "Parent", workspaces: [Self.row("a")])), .group(sub),
        ])]
        #expect(SidebarEdits.apply(.closeGroup(GroupID("g")), to: &sections))
        guard case let .group(lifted) = sections[0].nodes.first else { Issue.record("no group"); return }
        #expect(lifted.id == GroupID("s") && lifted.parent == nil && lifted.name == "Sub")
    }

    /// A workspace listed twice keeps each listing's own row through an edit.
    @Test func aWorkspaceListedTwiceKeepsEachRow() {
        var pinnedCopy = Self.row("a")
        pinnedCopy.title = "pinned a"
        var sections = [
            SidebarSection(kind: .pinned, nodes: [.workspace(pinnedCopy)]),
            SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("b")), .workspace(Self.row("a"))]),
        ]
        #expect(SidebarEdits.apply(.reorder([WorkspaceID("b")], to: DropPosition(section: .machine(.local), index: 1)), to: &sections))
        #expect(sections[0].workspaces.map(\.title) == ["pinned a"])
        #expect(sections[1].workspaces.map(\.title) == ["title a", "title b"])
    }

    @Test func fieldWritesStayOnTheRow() {
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("a"))])]
        #expect(SidebarEdits.apply(.rename(WorkspaceID("a"), "renamed"), to: &sections))
        #expect(sections[0].workspaces.first?.title == "renamed")
        #expect(!SidebarEdits.apply(.select(WorkspaceID("a")), to: &sections))
    }
}
