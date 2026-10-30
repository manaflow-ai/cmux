import CmuxNextDesign
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// Leo 2026-10-29: "why is there all this weird stuff at the bottom of the sidebar", "the rendering gets borked there
/// too :(". An agent started with `--group X` makes a group named X holding one workspace named X, so the sidebar said
/// the name twice: a header, then an indented member of the same name. A group whose one member is titled as the group
/// draws one row: the member's, in the header's place, still in the group (its rail, its color, its menu).
@MainActor struct SidebarSingleMemberGroupTests {
    private let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    /// Computed, so the fonts it reads are made on the main actor, never in the suite's nonisolated init.
    private var metrics: SidebarLayoutMetrics { .standard }

    private func ws(_ id: String, _ title: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: title) }

    private func layout(_ nodes: [SidebarNode], options: SidebarLayoutOptions = SidebarLayoutOptions()) -> SidebarLayout {
        SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], metrics: metrics, options: options)
    }

    @Test func aMemberNamedAsItsGroupDrawsOneRowInTheHeadersPlace() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", color: .purple, workspaces: [ws("w-coord", " release-coord ")])
        let plain = SidebarGroup(id: GroupID("g-plain"), name: "Plain", color: .green, workspaces: [ws("w-plain", "Plain notes")])
        let reference = layout([.workspace(ws("w-loose", "loose")), .group(plain)])
        let layout = layout([.workspace(ws("w-loose", "loose")), .group(group)])
        #expect(layout.row(for: .group(GroupID("g-coord"))) == nil, "no header repeats the name")
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let header = try #require(reference.row(for: .group(GroupID("g-plain"))))
        #expect(row.y == header.y, "the member takes the header's place")
        #expect(row.depth == header.depth + 1, "at the header's indent: a top-level group's rows are flush with loose rows")
        #expect(row.group == GroupID("g-coord"), "still the group's member: its rail and color")
        #expect(row.groupColor == .purple)
        #expect(row.parentIndex == 1)
        #expect(row.siblingIndex == 0)
        #expect(row.isLastInGroup)
        #expect(row.standsForGroup)
        #expect(layout.rows.count == 2, "the loose row and the one member row")
        #expect(layout.totalHeight < reference.totalHeight, "one row fewer")
    }

    @Test func aMemberNamedOtherwiseKeepsItsHeader() throws {
        let group = SidebarGroup(id: GroupID("g-plain"), name: "Plain", workspaces: [ws("w-plain", "Plain notes")])
        let layout = layout([.group(group)])
        let header = try #require(layout.row(for: .group(GroupID("g-plain"))))
        let member = try #require(layout.row(for: .workspace(WorkspaceID("w-plain"))))
        #expect(member.y > header.y)
        #expect(member.depth == header.depth + 1)
        #expect(!member.standsForGroup)
    }

    @Test func twoMembersKeepTheHeaderEvenWhenOneSharesItsName() throws {
        let group = SidebarGroup(id: GroupID("g-two"), name: "release-coord",
                                 workspaces: [ws("w-a", "release-coord"), ws("w-b", "release-notes")])
        let layout = layout([.group(group)])
        #expect(layout.row(for: .group(GroupID("g-two"))) != nil)
        #expect(layout.rows.map(\.key) == [.group(GroupID("g-two")), .workspace(WorkspaceID("w-a")), .workspace(WorkspaceID("w-b"))])
        #expect(layout.rows.allSatisfy { !$0.standsForGroup })
    }

    /// A nested group of one same-named member (a subgroup under "Design review") draws one row at the subgroup's
    /// header depth, inside its parent.
    @Test func aNestedSameNameGroupDrawsOneRowAtItsHeadersDepth() throws {
        let parent = SidebarGroup(id: GroupID("g-design"), name: "Design review", color: .blue,
                                  workspaces: [ws("w-sketch", "Sketches")])
        var child = SidebarGroup(id: GroupID("g-visual"), name: "visual-check", color: .orange, workspaces: [ws("w-visual", "visual-check")])
        child.parent = parent.id
        child.depth = 1
        var otherChild = SidebarGroup(id: GroupID("g-other"), name: "Other", color: .orange, workspaces: [ws("w-other", "Other notes")])
        otherChild.parent = parent.id
        otherChild.depth = 1
        let reference = layout([.group(parent), .group(otherChild)])
        let layout = layout([.group(parent), .group(child)])
        #expect(layout.row(for: .group(GroupID("g-visual"))) == nil)
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-visual"))))
        let header = try #require(reference.row(for: .group(GroupID("g-other"))))
        #expect(row.y == header.y)
        #expect(row.depth == header.depth + 1)
        #expect(row.indentLevel == header.indentLevel, "the subgroup header's indent")
        #expect(row.group == GroupID("g-visual"))
        #expect(row.standsForGroup)
    }

    /// A group holding a subgroup keeps its header: the subgroup hangs under it.
    @Test func aGroupWithSubgroupsKeepsItsHeader() {
        let parent = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        var child = SidebarGroup(id: GroupID("g-sub"), name: "Sub", workspaces: [ws("w-sub", "sub")])
        child.parent = parent.id
        child.depth = 1
        let layout = layout([.group(parent), .group(child)])
        #expect(layout.row(for: .group(GroupID("g-coord"))) != nil)
    }

    /// A collapsed group of one same-named member still draws that member's row (its spinner and unread stay seen).
    @Test func aCollapsedSameNameGroupDrawsTheMember() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", isCollapsed: true, workspaces: [ws("w-coord", "release-coord")])
        let layout = layout([.group(group)])
        #expect(layout.row(for: .group(GroupID("g-coord"))) == nil)
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        #expect(row.standsForGroup)
    }

    /// A drag's gap in the group opens around the one row: the header does not come back mid-drag.
    @Test func aDropGapInTheGroupKeepsOneRow() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        var options = SidebarLayoutOptions()
        options.gap = DropPosition(section: .machine(machine.id), group: group.id, index: 0)
        options.gapHeight = 30
        let layout = layout([.group(group)], options: options)
        #expect(layout.row(for: .group(GroupID("g-coord"))) == nil)
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let gapY = try #require(layout.gapY)
        #expect(gapY < row.y, "the gap opens above the row")
    }

    /// The group's line runs along the one row, at the header bar's left edge, in the group's color.
    @Test func theOneRowCarriesTheGroupsLine() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", color: .purple, workspaces: [ws("w-coord", "release-coord")])
        let layout = layout([.group(group)])
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let frame = CGRect(x: 20, y: row.y, width: 200, height: row.height)
        let lines = SidebarGroupLine.lines(layout.rows, colors: [group.id: group]) { _ in frame }
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line.group == group.id)
        #expect(line.frame.minY == frame.minY)
        #expect(line.frame.maxY == frame.maxY)
        #expect(line.frame.minX == SidebarStyle.groupBarX(membersMinX: frame.minX))
        #expect(line.frame.width == SidebarStyle.groupBarWidth)
    }
}
