import CmuxNextDesign
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// An empty group keeps only its header. Creation stays on the header's hover +,
/// and dropping a workspace on that header still inserts it into the group.
@MainActor struct SidebarEmptyGroupTests {
    private let scratch = GroupID("g_scratch"), perf = GroupID("g_perf")
    private let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private func sections(scratchCollapsed: Bool = false) -> [SidebarSection] {
        let empty = SidebarGroup(id: scratch, name: "Scratch", isCollapsed: scratchCollapsed, workspaces: [])
        let full = SidebarGroup(id: perf, name: "Performance", workspaces: [SidebarWorkspace(id: WorkspaceID("p1"), title: "p1")])
        return [SidebarSection(kind: .machine(machine), nodes: [
            .group(empty),
            .group(full),
            .workspace(SidebarWorkspace(id: WorkspaceID("loose"), title: "loose")),
        ])]
    }

    private func layout(_ sections: [SidebarSection], filter: Set<WorkspaceID>? = nil) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.filterMatches = filter
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    /// The row right under `group`'s header that belongs to it, if any.
    private func rowUnderHeader(_ layout: SidebarLayout, _ group: GroupID) -> SidebarRow? {
        guard let header = layout.rows.firstIndex(where: { $0.key == .group(group) }), header + 1 < layout.rows.count else { return nil }
        let next = layout.rows[header + 1]
        return next.group == group ? next : nil
    }

    @Test func anOpenEmptyGroupKeepsOnlyItsHeader() throws {
        let layout = layout(sections())
        let header = try #require(layout.row(for: .group(scratch)))
        #expect(rowUnderHeader(layout, scratch) == nil)
        #expect(layout.row(for: .emptyGroup(scratch)) == nil)
        let next = try #require(layout.row(for: .group(perf)))
        #expect(next.y == header.maxY + SidebarLayoutMetrics.standard.rowSpacing)
    }

    @Test func aCollapsedEmptyGroupStaysAHeaderAlone() {
        let layout = layout(sections(scratchCollapsed: true))
        #expect(rowUnderHeader(layout, scratch) == nil)
    }

    @Test func aFilterShowsNoEmptyRow() {
        let layout = layout(sections(), filter: [WorkspaceID("p1")])
        #expect(rowUnderHeader(layout, scratch) == nil)
    }

    @Test func aGroupWithMembersHasNoEmptyRow() throws {
        let layout = layout(sections())
        let row = try #require(rowUnderHeader(layout, perf))
        #expect(row.key == .workspace(WorkspaceID("p1")))
    }

    /// A group whose only children are subgroups is not empty: its subgroups follow it.
    @Test func aGroupHoldingOnlySubgroupsHasNoEmptyRow() {
        var parent = SidebarGroup(id: scratch, name: "Scratch", workspaces: [])
        parent.depth = 0
        var child = SidebarGroup(id: perf, name: "Performance", workspaces: [SidebarWorkspace(id: WorkspaceID("p1"), title: "p1")])
        child.parent = scratch
        child.depth = 1
        let layout = layout([SidebarSection(kind: .machine(machine), nodes: [.group(parent), .group(child)])])
        let headerIndex = layout.rows.firstIndex { $0.key == .group(scratch) } ?? -1
        #expect(layout.rows[headerIndex + 1].key == .group(perf), "the subgroup comes right after its parent")
    }

    /// The fast fold (`SidebarLayout.folding`) gives the same rows as a full layout for an empty group, both ways.
    @Test func foldingAnEmptyGroupMatchesAFullLayout() throws {
        let open = layout(sections()), closed = layout(sections(scratchCollapsed: true))
        let section = try #require(sections().first)
        guard case var .group(group)? = section.nodes.first else {
            Issue.record("fixture")
            return
        }
        let folded = try #require(open.folding(group, collapsed: true, in: section, metrics: .standard, options: SidebarLayoutOptions()))
        #expect(folded.rows == closed.rows)
        #expect(folded.totalHeight == closed.totalHeight)
        group.isCollapsed = true
        let unfolded = try #require(closed.folding(group, collapsed: false, in: section, metrics: .standard, options: SidebarLayoutOptions()))
        #expect(unfolded.rows == open.rows)
        #expect(unfolded.totalHeight == open.totalHeight)
    }

    /// A loose workspace dragged over the empty header drops into the group, at its start.
    @Test func aDropOnTheEmptyHeaderGoesIntoTheGroup() throws {
        let sections = sections()
        let layout = layout(sections)
        let header = try #require(layout.row(for: .group(scratch)))
        let y = header.y + header.height / 2
        let resolved = try #require(DropResolver.resolveDrag(centreY: y, leadingY: y, gapY: nil, gapHeight: 0,
                                                             payload: .workspaces([WorkspaceID("loose")]), base: layout, sections: sections))
        let section = try #require(sections.first?.id)
        #expect(resolved.target == .position(DropPosition(section: section, group: scratch, index: 0)))
    }
}
