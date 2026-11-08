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
    /// Review on #27875 at 638b2953: a filter that shows only the same-named member of a two-member group leaves that
    /// group with its header, since the group holds two. One row there would carry the group's drag, and a drag of the
    /// matching workspace would move the hidden member too.
    @Test func aFilterShowingOneOfTwoMembersKeepsTheHeader() throws {
        let group = SidebarGroup(id: GroupID("g-release"), name: "Release", workspaces: [ws("w-release", "Release"), ws("w-notes", "Notes")])
        var options = SidebarLayoutOptions()
        options.filterMatches = [WorkspaceID("w-release")]
        let layout = layout([.group(group)], options: options)
        #expect(layout.row(for: .workspace(WorkspaceID("w-notes"))) == nil, "the filter hides the other member")
        #expect(layout.row(for: .group(GroupID("g-release"))) != nil, "a filtered group of two keeps its header")
        #expect(layout.row(for: .workspace(WorkspaceID("w-release")))?.standsForGroup == false, "the matching workspace stays a workspace row")
    }

    /// Review on #27875 at e40af6fb: a drag of B out of group G (members G and B) lays the list out without B, and its
    /// preview lays it out with B moved out. Both must agree on G's header, or the drop's coordinates shift by a header:
    /// the dragged-out member does not count, as in the preview, while a member a filter hides does.
    @Test func aMemberDraggedOutCountsAsMovedOut() throws {
        let group = SidebarGroup(id: GroupID("g"), name: "G", workspaces: [ws("w-g", "G"), ws("w-b", "B")])
        var dragging = SidebarLayoutOptions()
        dragging.excludedWorkspaces = [WorkspaceID("w-b")]
        let base = layout([.group(group), .workspace(ws("w-c", "C"))], options: dragging)
        let moved = SidebarGroup(id: GroupID("g"), name: "G", workspaces: [ws("w-g", "G")])
        let preview = layout([.group(moved), .workspace(ws("w-b", "B")), .workspace(ws("w-c", "C"))])
        #expect((base.row(for: .group(GroupID("g"))) == nil) == (preview.row(for: .group(GroupID("g"))) == nil),
                "the drag's base and its preview disagree on G's header")
        #expect(base.row(for: .workspace(WorkspaceID("w-g")))?.standsForGroup == true)
        #expect(base.row(for: .workspace(WorkspaceID("w-c")))?.y == preview.row(for: .workspace(WorkspaceID("w-b")))?.y,
                "C sits where the preview puts B: no header's height between them")
    }

    @Test func aGroupWithSubgroupsKeepsItsHeader() {
        let parent = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        var child = SidebarGroup(id: GroupID("g-sub"), name: "Sub", workspaces: [ws("w-sub", "sub")])
        child.parent = parent.id
        child.depth = 1
        let layout = layout([.group(parent), .group(child)])
        #expect(layout.row(for: .group(GroupID("g-coord"))) != nil)
    }

    /// A collapsed group of one same-named member draws as on base: its header alone, unless the member is kept shown
    /// in it (the active workspace), and then that member's one row.
    @Test func aCollapsedSameNameGroupFoldsAsBefore() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", isCollapsed: true, workspaces: [ws("w-coord", "release-coord")])
        #expect(layout([.group(group)]).rows.map(\.key) == [.group(GroupID("g-coord"))], "folded: the header alone")
        var options = SidebarLayoutOptions()
        options.activeWorkspaceID = WorkspaceID("w-coord")
        let kept = layout([.group(group)], options: options)
        #expect(kept.row(for: .group(GroupID("g-coord"))) == nil)
        let row = try #require(kept.row(for: .workspace(WorkspaceID("w-coord"))))
        #expect(row.standsForGroup)
    }

    /// Astra review: with Done folding on, a same-named member marked Done goes into the group's "Done (1)" row, exactly
    /// as on base (header, then the fold); opened, the fold lists it under the fold row.
    @Test func aDoneSoleMemberStaysInTheDoneFold() throws {
        var member = ws("w-coord", "release-coord")
        member.taskStatus = .done
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [member])
        let fold = SidebarDoneFoldID(section: .machine(machine.id), group: group.id)
        var options = SidebarLayoutOptions()
        options.foldsDone = true
        let folded = layout([.group(group)], options: options)
        #expect(folded.rows.map(\.key) == [.group(group.id), .doneFold(fold)])
        #expect(try #require(folded.row(for: .doneFold(fold))).childCount == 1, "Done (1)")
        options.openDoneFolds = [fold]
        let opened = layout([.group(group)], options: options)
        #expect(opened.rows.map(\.key) == [.group(group.id), .doneFold(fold), .workspace(member.id)])
        #expect(opened.rows.allSatisfy { !$0.standsForGroup })
    }

    /// A drag's gap in the group opens under the one row, as it opened under the header: the row keeps the header's slot.
    @Test func aDropGapInTheGroupOpensUnderTheRow() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        var options = SidebarLayoutOptions()
        options.gap = DropPosition(section: .machine(machine.id), group: group.id, index: 0)
        options.gapHeight = 30
        let layout = layout([.group(group)], options: options)
        #expect(layout.row(for: .group(GroupID("g-coord"))) == nil)
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let gapY = try #require(layout.gapY)
        #expect(row.y == metrics.topPadding, "the row stays in the header's slot")
        #expect(gapY >= row.maxY, "the gap opens under the row")
    }

    /// Astra review: the one row sits in the header's slot, so a drop resolves as on the header: its upper edge before the
    /// group, its body into the group at its start.
    @Test func aDropOnTheOneRowResolvesAsOnTheHeader() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        let sections = [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w-loose", "loose")), .group(group)])]
        let layout = SidebarLayout.make(sections: sections, metrics: metrics)
        let row = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let section = SectionID.machine(machine.id)
        func target(_ fraction: CGFloat) -> DropTarget? {
            DropResolver.resolve(y: row.y + row.height * fraction, payload: .workspaces([WorkspaceID("w-loose")]), base: layout,
                                 sections: sections, onto: (0, 0))
        }
        #expect(target(0.1) == .position(DropPosition(section: section, group: nil, index: 1)), "upper edge: before the group")
        #expect(target(0.6) == .position(DropPosition(section: section, group: group.id, index: 0)), "body: into the group")
        #expect(target(0.95) == .position(DropPosition(section: section, group: group.id, index: 0)), "lower half: into the group")
    }

    /// A parent whose own members are all behind its closed "Done (N)" row still draws a subgroup when that subgroup is
    /// one same-named row: the drop resolver reads the parent as open, as it did with the subgroup's header, so a drop
    /// on the parent header's body goes into the parent at its start (not "into" a folded group).
    @Test func aParentOfASoleRowSubgroupStaysOpenForDrops() throws {
        var done = ws("w-old", "Old notes")
        done.taskStatus = .done
        let parent = SidebarGroup(id: GroupID("g-design"), name: "Design review", workspaces: [done])
        var child = SidebarGroup(id: GroupID("g-visual"), name: "visual-check", workspaces: [ws("w-visual", "visual-check")])
        child.parent = parent.id
        child.depth = 1
        let sections = [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w-loose", "loose")), .group(parent), .group(child)])]
        var options = SidebarLayoutOptions()
        options.foldsDone = true
        let layout = SidebarLayout.make(sections: sections, metrics: metrics, options: options)
        #expect(try #require(layout.row(for: .workspace(WorkspaceID("w-visual")))).standsForGroup)
        let header = try #require(layout.row(for: .group(parent.id)))
        let target = DropResolver.resolve(y: header.y + header.height * 0.6, payload: .workspaces([WorkspaceID("w-loose")]), base: layout,
                                          sections: sections, onto: (0, 0))
        #expect(target == .position(DropPosition(section: .machine(machine.id), group: parent.id, index: 0)))
    }

    /// Sol review: whether a group draws one row depends on its member's title, so a rename into or out of the group's
    /// name is a structural change, never an in-place row patch (which keeps the old header or one row).
    @Test func aRenameIntoOrOutOfTheGroupNameRebuildsTheRows() throws {
        func sections(_ title: String) -> [SidebarSection] {
            [SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", title)])),
            ])]
        }
        let into = SidebarModel(sections: sections("Draft"))
        #expect(!into.patchWorkspaces([ws("w-coord", "release-coord")]), "renamed into the group's name: not a patch")
        let outOf = SidebarModel(sections: sections("release-coord"))
        #expect(!outOf.patchWorkspaces([ws("w-coord", "release-coord notes")]), "renamed out of the group's name: not a patch")
        // A rename that keeps the name's match, or a status tick, still patches in place.
        let tick = SidebarModel(sections: sections("release-coord"))
        var busy = ws("w-coord", " release-coord ")
        busy.activity = .busy(progress: nil)
        #expect(tick.patchWorkspaces([busy]))
        let other = SidebarModel(sections: sections("Draft"))
        #expect(other.patchWorkspaces([ws("w-coord", "Draft 2")]))
    }

    /// Astra review: a workspace listed twice (cf. #28033) is checked copy by copy: a rename that turns the group copy
    /// into its group's one row rebuilds the rows even when another copy already had the new title.
    @Test func aRenameFlippingAnyListedCopyRebuildsTheRows() throws {
        let other = SidebarMachine(id: MachineID("m-other"), name: "Other", kind: .ssh)
        let grouped = SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "Draft")])),
        ])
        let loose = SidebarSection(kind: .machine(other), nodes: [.workspace(ws("w-coord", "release-coord"))])
        for sections in [[loose, grouped], [grouped, loose]] {
            let model = SidebarModel(sections: sections)
            var renamed = ws("w-coord", "release-coord")
            renamed.activity = .busy(progress: nil)
            #expect(!model.patchWorkspaces([renamed]), "the group copy becomes the group's one row: not a patch")
        }
    }

    /// Sol review: a group drag cuts the list into top-level blocks; the one row starts its own group's block (as its
    /// header did), never joining the open group above it.
    @Test func aGroupDragCutsTheOneRowIntoItsOwnBlock() throws {
        let alpha = SidebarGroup(id: GroupID("g-alpha"), name: "Alpha", workspaces: [ws("w-a1", "a1"), ws("w-a2", "a2")])
        let coord = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        let layout = SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: [.group(alpha), .group(coord)])],
                                        metrics: metrics)
        let one = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let blocks = SidebarGroupDragPlan.blocks(of: layout.rows)
        let block = try #require(blocks.first { $0.range.contains(one.y + 1) })
        #expect(block.head.key == .group(coord.id), "the one row joined \(block.head.key)'s block")
        #expect(block.head.siblingIndex == 1, "its group's place in the section")
        #expect(block.nextIndex == 2)
    }

    /// Sol review: the document drag reads the one row as its group's slot, as it read the header: its top band drops
    /// before the group, its middle into it, its bottom band after it (out of a nested group too).
    @Test func aDocumentDropOnTheOneRowGoesBeforeIntoOrAfterTheGroup() throws {
        let group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", workspaces: [ws("w-coord", "release-coord")])
        let sections = [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w-loose", "loose")), .group(group)])]
        let layout = SidebarLayout.make(sections: sections, metrics: metrics, options: SidebarLayoutOptions())
        let doc = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(id): "g_\(id.rawValue)"
            default: nil
            }
        }, section: { _ in "sec" }, begin: { _ in [:] }, drop: { _, _ in })
        let (geometry, rows) = doc.geometry(layout, width: 240, acceptance: [:])
        let one = try #require(layout.row(for: .workspace(WorkspaceID("w-coord"))))
        let span = one.height
        func target(_ fraction: CGFloat) -> SidebarDocTarget? { geometry.hit(CGPoint(x: 100, y: one.y + span * fraction))?.target }
        #expect(target(0.1) == SidebarDocTarget(section: "sec", before: "g_g-coord"), "top band: before the group")
        #expect(target(0.5) == SidebarDocTarget(section: "sec", parent: "g_g-coord"), "middle: into the group")
        #expect(target(0.9) == SidebarDocTarget(section: "sec", after: "g_g-coord"), "bottom band: after the group")
        let hit = try #require(geometry.hit(CGPoint(x: 100, y: one.y + span / 2)))
        #expect(rows[hit.slot.key].map { SidebarDocDrag.display(hit, row: $0) } == .intoGroup(group.id), "the drop look fills the group")
    }

    /// Sol review: opening a folded same-named single-member group draws its one row, as a full layout does (the
    /// fold's splice assumes a header over member rows, so it leaves this group to the full layout).
    @Test func openingAFoldedSameNameGroupMatchesAFullLayout() throws {
        var group = SidebarGroup(id: GroupID("g-coord"), name: "release-coord", isCollapsed: true, workspaces: [ws("w-coord", "release-coord")])
        let section = SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w-loose", "loose")), .group(group)])
        let folded = SidebarLayout.make(sections: [section], metrics: metrics)
        #expect(folded.row(for: .group(group.id)) != nil, "folded: the header")
        group.isCollapsed = false
        let open = SidebarLayout.make(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("w-loose", "loose")), .group(group)])],
                                      metrics: metrics)
        if let spliced = folded.folding(group, collapsed: false, in: section, metrics: metrics, options: SidebarLayoutOptions()) {
            #expect(spliced.rows == open.rows, "the splice gives the full layout's rows")
            #expect(spliced.totalHeight == open.totalHeight)
        }
        #expect(open.row(for: .group(group.id)) == nil)
        #expect(try #require(open.row(for: .workspace(WorkspaceID("w-coord")))).standsForGroup)
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
