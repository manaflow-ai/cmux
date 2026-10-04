import CoreGraphics
import Testing
@testable import CmuxNextSidebar

// MARK: - Reorder application

@Suite struct ReorderApplication {
    @Test func movesWithinSectionUsingPostRemovalIndex() {
        var s = fixture()
        // After removing a: [G1, b, G2, c]; index 2 is before G2.
        #expect(SidebarEdits.apply(.reorder([id("a")], to: DropPosition(section: local, index: 2)), to: &s))
        #expect(shape(s, local) == "G1[g1,g2,g3] b a G2[h1,h2] c")
    }

    @Test func movesToTop() {
        var s = fixture()
        SidebarEdits.apply(.reorder([id("c")], to: DropPosition(section: local, index: 0)), to: &s)
        #expect(shape(s, local) == "c a G1[g1,g2,g3] b G2[h1,h2]")
    }

    @Test func multiSelectionMovesInTreeOrderIntoGroup() {
        var s = fixture()
        // Selection order is reversed; the tree order wins.
        SidebarEdits.apply(.reorder([id("b"), id("a")], to: DropPosition(section: local, group: g1, index: 1)), to: &s)
        #expect(shape(s, local) == "G1[g1,a,b,g2,g3] G2[h1,h2] c")
    }

    @Test func movesOutOfGroup() {
        var s = fixture()
        SidebarEdits.apply(.reorder([id("g2")], to: DropPosition(section: local, index: 0)), to: &s)
        #expect(shape(s, local) == "g2 a G1[g1,g3] b G2[h1,h2] c")
    }

    @Test func emptiedSourceGroupIsPrunedButTargetGroupIsKept() {
        var s = fixture()
        SidebarEdits.apply(.reorder([id("h1"), id("h2")], to: DropPosition(section: local, index: 0)), to: &s)
        #expect(shape(s, local) == "h1 h2 a G1[g1,g2,g3] b c")
    }

    @Test func refusesCrossMachineMove() {
        var s = fixture()
        let before = s
        #expect(!SidebarEdits.apply(.reorder([id("x")], to: DropPosition(section: local, index: 0)), to: &s))
        #expect(s == before)
    }

    @Test func refusesMixedMachineMove() {
        var s = fixture()
        let before = s
        #expect(!SidebarEdits.apply(.reorder([id("a"), id("x")], to: DropPosition(section: local, index: 0)), to: &s))
        #expect(s == before)
    }

    @Test func pinsFromAnyMachine() {
        var s = fixture()
        SidebarEdits.apply(.reorder([id("x"), id("a")], to: DropPosition(section: .pinned, index: 1)), to: &s)
        #expect(shape(s, .pinned) == "p1 a x")
        #expect(shape(s, cloudSection) == "y")
    }

    @Test func refusesGroupPositionInPinned() {
        var s = fixture()
        #expect(!SidebarEdits.apply(.reorder([id("a")], to: DropPosition(section: .pinned, group: g1, index: 0)), to: &s))
    }

    @Test func noOpMoveReportsNoChange() {
        var s = fixture()
        // b sits at index 2; after removal index 2 is its own slot.
        #expect(!SidebarEdits.apply(.reorder([id("b")], to: DropPosition(section: local, index: 2)), to: &s))
    }

    @Test func moveToGroupAppends() {
        var s = fixture()
        SidebarEdits.apply(.move([id("g1"), id("c")], toGroup: g2), to: &s)
        #expect(shape(s, local) == "a G1[g2,g3] b G2[h1,h2,g1,c]")
    }

    @Test func createGroupAnchorsAtFirstItemInTreeOrder() {
        var s = fixture()
        let new = GroupID("N")
        SidebarEdits.apply(.createGroup(new, name: "N", color: .red, workspaces: [id("b"), id("g2")]), to: &s)
        #expect(shape(s, local) == "a G1[g1,g3] N[g2,b] G2[h1,h2] c")
    }

    @Test func createGroupFromLooseItems() {
        var s = fixture()
        let new = GroupID("N")
        SidebarEdits.apply(.createGroup(new, name: "N", color: .red, workspaces: [id("c"), id("a")]), to: &s)
        #expect(shape(s, local) == "N[a,c] G1[g1,g2,g3] b G2[h1,h2]")
    }

    @Test func createGroupIgnoresOtherSectionsAndRefusesPinned() {
        var s = fixture()
        SidebarEdits.apply(.createGroup(GroupID("N"), name: "N", color: .red, workspaces: [id("a"), id("x")]), to: &s)
        #expect(shape(s, local).hasPrefix("N[a]"))
        #expect(shape(s, cloudSection) == "x y")
        #expect(!SidebarEdits.apply(.createGroup(GroupID("P"), name: "P", color: .red, workspaces: [id("p1")]), to: &s))
    }

    @Test func ungroupLeavesChildrenInPlace() {
        var s = fixture()
        SidebarEdits.apply(.ungroup(g1), to: &s)
        #expect(shape(s, local) == "a g1 g2 g3 b G2[h1,h2] c")
    }

    @Test func reorderGroupUsesIndexExcludingGroup() {
        var s = fixture()
        SidebarEdits.apply(.reorderGroup(g2, index: 0), to: &s)
        #expect(shape(s, local) == "G2[h1,h2] a G1[g1,g2,g3] b c")
        SidebarEdits.apply(.reorderGroup(g2, index: 99), to: &s)
        #expect(shape(s, local) == "a G1[g1,g2,g3] b c G2[h1,h2]")
    }

    @Test func unpinReturnsToOwnMachineTop() {
        var s = fixture()
        SidebarEdits.apply(.setPinned([id("x")], true), to: &s)
        #expect(shape(s, .pinned) == "p1 x")
        SidebarEdits.apply(.setPinned([id("x"), id("p1")], false), to: &s)
        #expect(shape(s, .pinned) == "")
        #expect(shape(s, cloudSection) == "x y")
        #expect(shape(s, local).hasPrefix("p1 a"))
    }

    @Test func closePrunesEmptiedGroups() {
        var s = fixture()
        SidebarEdits.apply(.close([id("h1"), id("h2"), id("a")]), to: &s)
        #expect(shape(s, local) == "G1[g1,g2,g3] b c")
    }

    @Test func setColorTintsSymbolsAndRecolorsSwatches() {
        var s = fixture()
        // Rows have no icon by default; a color alone becomes a swatch.
        #expect(SidebarEdits.workspace(id("a"), in: s)?.icon == nil)
        SidebarEdits.apply(.setColor([id("a")], .red), to: &s)
        #expect(SidebarEdits.workspace(id("a"), in: s)?.icon == .swatch(.red))
        SidebarEdits.apply(.setColor([id("a")], nil), to: &s)
        #expect(SidebarEdits.workspace(id("a"), in: s)?.icon == nil)
        SidebarEdits.apply(.setIcon([id("a")], .symbol("terminal")), to: &s)
        SidebarEdits.apply(.setColor([id("a")], .red), to: &s)
        #expect(SidebarEdits.workspace(id("a"), in: s)?.icon == .symbol("terminal", tint: .red))
        SidebarEdits.apply(.setIcon([id("a")], .swatch(.blue)), to: &s)
        SidebarEdits.apply(.setColor([id("a")], .pink), to: &s)
        #expect(SidebarEdits.workspace(id("a"), in: s)?.icon == .swatch(.pink))
    }
}

// MARK: - Layout

@Suite struct Layout {
    let m = SidebarLayoutMetrics.standard

    @Test func collapsedGroupHidesChildrenAndCountsNodes() {
        let layout = SidebarLayout.make(sections: fixture(), metrics: m)
        #expect(layout.row(for: .workspace(id("h1"))) == nil)
        #expect(layout.row(for: .workspace(id("g1"))) != nil)
        #expect(layout.row(for: .section(local))?.childCount == 5)
        let g1Row = layout.row(for: .workspace(id("g3")))!
        #expect(g1Row.isLastInGroup)
        #expect(g1Row.parentIndex == 1)
        #expect(g1Row.groupColor == .purple)
    }

    @Test func rowsStackWithSpacing() {
        let layout = SidebarLayout.make(sections: fixture(), metrics: m)
        let a = layout.row(for: .workspace(id("a")))!
        let header = layout.row(for: .group(g1))!
        #expect(header.y == a.maxY + m.rowSpacing)
        for (prev, next) in zip(layout.rows, layout.rows.dropFirst()) {
            #expect(next.y >= prev.maxY)
        }
    }

    @Test func emptyPinnedHidesUnlessDragging() {
        var s = fixture()
        s[0].nodes = []
        #expect(SidebarLayout.make(sections: s, metrics: .standard).row(for: .section(.pinned)) == nil)
        var o = SidebarLayoutOptions()
        o.showEmptyPinned = true
        #expect(SidebarLayout.make(sections: s, metrics: .standard, options: o).row(for: .emptySection(.pinned)) != nil)
    }

    @Test func gapShiftsFollowingRows() {
        let base = SidebarLayout.make(sections: fixture(), metrics: m)
        var o = SidebarLayoutOptions()
        o.gap = DropPosition(section: local, index: 2)
        o.gapHeight = 40
        let gapped = SidebarLayout.make(sections: fixture(), metrics: m, options: o)
        let bBase = base.row(for: .workspace(id("b")))!
        let bGapped = gapped.row(for: .workspace(id("b")))!
        #expect(gapped.gapY == bBase.y)
        #expect(bGapped.y == bBase.y + 40 + m.rowSpacing)
        #expect(gapped.row(for: .workspace(id("a")))!.y == base.row(for: .workspace(id("a")))!.y)
    }

    @Test func excludedRowsRenumberSiblings() {
        var o = SidebarLayoutOptions()
        o.excludedWorkspaces = [id("a")]
        let layout = SidebarLayout.make(sections: fixture(), metrics: m, options: o)
        #expect(layout.row(for: .workspace(id("a"))) == nil)
        #expect(layout.row(for: .group(g1))?.siblingIndex == 0)
        #expect(layout.row(for: .workspace(id("b")))?.siblingIndex == 1)
    }

    @Test func filterShowsMatchesAndForceExpands() {
        var o = SidebarLayoutOptions()
        o.filterMatches = SidebarFilter.matches("H2", in: fixture())
        let layout = SidebarLayout.make(sections: fixture(), metrics: m, options: o)
        #expect(layout.rows.map(\.key) == [.section(local), .group(g2), .workspace(id("h2"))])
    }

    @Test func filterIsDiacriticAndCaseInsensitive() {
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "L", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: id("r"), title: "Résumé builder", subtitle: "main")),
        ])]
        #expect(SidebarFilter.matches("resume MAIN", in: sections) == [id("r")])
        #expect(SidebarFilter.matches("   ", in: sections) == nil)
    }

    @Test func optionalTabRowsFollowWorkspaceRows() {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(
            id: id("a"), title: "a",
            tabs: [SidebarTab(id: TabID("t1"), title: "Terminal"),
                   SidebarTab(id: TabID("t2"), title: "Browser", kind: .browser)]
        ))
        var options = SidebarLayoutOptions()
        options.showWorkspaceTabs = true
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(id("a"))) != nil)
        #expect(layout.row(for: .tab(id("a"), TabID("t1")))?.workspace == id("a"))
        #expect(layout.row(for: .tab(id("a"), TabID("t2")))?.tabKind == .browser)

        let withoutTabs = SidebarLayout.make(sections: sections, metrics: .standard)
        #expect(withoutTabs.row(for: .tab(id("a"), TabID("t1"))) == nil)
    }

    @Test func tabRowsUseTheWorkspaceAsTheirDropTarget() throws {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(
            id: id("a"), title: "a", tabs: [SidebarTab(id: TabID("t1"), title: "Terminal")]
        ))
        var options = SidebarLayoutOptions()
        options.showWorkspaceTabs = true
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
        let row = try #require(layout.row(for: .tab(id("a"), TabID("t1"))))
        #expect(DropResolver.resolveTabDrop(y: row.y + row.height / 2, base: layout, sections: sections, sourceMachine: .local) == .intoWorkspace(id("a")))
    }
}

// MARK: - Drop position math

@Suite struct DropMath {
    let sections = fixture()

    func base(excluding ids: [String] = [], group: GroupID? = nil) -> SidebarLayout {
        var o = SidebarLayoutOptions()
        o.excludedWorkspaces = Set(ids.map(id))
        o.excludedGroup = group
        o.showEmptyPinned = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: o)
    }

    func y(_ key: SidebarRowKey, _ fraction: CGFloat, in layout: SidebarLayout) -> CGFloat {
        let row = layout.row(for: key)!
        return row.y + row.height * fraction
    }

    func resolve(_ key: SidebarRowKey, _ fraction: CGFloat, dragging ids: [String]) -> DropTarget? {
        let layout = base(excluding: ids)
        return DropResolver.resolve(y: y(key, fraction, in: layout), payload: .workspaces(ids.map(id)), base: layout, sections: sections)
    }

    @Test func upperAndLowerHalfOfLooseRow() {
        // Dragging c: base is [a, G1, b, G2]; b has index 2.
        #expect(resolve(.workspace(id("b")), 0.2, dragging: ["c"]) == .position(DropPosition(section: local, index: 2)))
        #expect(resolve(.workspace(id("b")), 0.7, dragging: ["c"]) == .position(DropPosition(section: local, index: 3)))
    }

    @Test func rowsInsideExpandedGroup() {
        #expect(resolve(.workspace(id("g2")), 0.3, dragging: ["a"]) == .position(DropPosition(section: local, group: g1, index: 1)))
        #expect(resolve(.workspace(id("g2")), 0.6, dragging: ["a"]) == .position(DropPosition(section: local, group: g1, index: 2)))
    }

    @Test func bottomOfLastGroupedRowExitsGroup() {
        // Dragging a: G1 is section index 0, so "after G1" is index 1.
        #expect(resolve(.workspace(id("g3")), 0.6, dragging: ["a"]) == .position(DropPosition(section: local, group: g1, index: 3)))
        #expect(resolve(.workspace(id("g3")), 0.9, dragging: ["a"]) == .position(DropPosition(section: local, index: 1)))
    }

    @Test func collapsedGroupHeaderZones() {
        #expect(resolve(.group(g2), 0.1, dragging: ["a"]) == .position(DropPosition(section: local, index: 2)))
        #expect(resolve(.group(g2), 0.5, dragging: ["a"]) == .intoGroup(g2))
        #expect(resolve(.group(g2), 0.9, dragging: ["a"]) == .position(DropPosition(section: local, index: 3)))
    }

    @Test func expandedGroupHeaderZones() {
        #expect(resolve(.group(g1), 0.2, dragging: ["c"]) == .position(DropPosition(section: local, index: 1)))
        #expect(resolve(.group(g1), 0.7, dragging: ["c"]) == .position(DropPosition(section: local, group: g1, index: 0)))
    }

    @Test func sectionHeaderTargetsTopOrPreviousSectionEnd() {
        #expect(resolve(.section(local), 0.8, dragging: ["c"]) == .position(DropPosition(section: local, index: 0)))
        // Upper part of the local header means "end of pinned".
        #expect(resolve(.section(local), 0.1, dragging: ["c"]) == .position(DropPosition(section: .pinned, index: 1)))
    }

    @Test func crossMachineHoverIsRefused() {
        #expect(resolve(.workspace(id("b")), 0.3, dragging: ["x"]) == nil)
        #expect(resolve(.workspace(id("p1")), 0.3, dragging: ["x"]) == .position(DropPosition(section: .pinned, index: 0)))
    }

    @Test func pointerOutsideListClamps() {
        let layout = base(excluding: ["a"])
        let below = DropResolver.resolve(y: layout.totalHeight + 500, payload: .workspaces([id("a")]), base: layout, sections: sections)
        #expect(below == nil) // last row belongs to cloud; a is local
        let belowCloud = DropResolver.resolve(y: layout.totalHeight + 500, payload: .workspaces([id("x")]), base: base(excluding: ["x"]), sections: sections)
        #expect(belowCloud == .position(DropPosition(section: cloudSection, index: 1)))
    }

    @Test func gapCoordinateMapping() {
        #expect(DropResolver.baseY(forDisplayY: 50, gapY: 100, gapHeight: 40) == 50)
        #expect(DropResolver.baseY(forDisplayY: 120, gapY: 100, gapHeight: 40) == nil)
        #expect(DropResolver.baseY(forDisplayY: 160, gapY: 100, gapHeight: 40) == 120)
        #expect(DropResolver.baseY(forDisplayY: 160, gapY: nil, gapHeight: 0) == 160)
    }

    @Test func gapIsStableUnderPointer() {
        // Open the gap where the pointer resolved, then re-resolve from the
        // displayed layout: the target must not change.
        let ids = ["c"]
        let baseLayout = base(excluding: ids)
        let pointerBase = y(.workspace(id("b")), 0.7, in: baseLayout)
        let target = DropResolver.resolve(y: pointerBase, payload: .workspaces(ids.map(id)), base: baseLayout, sections: sections)
        guard case let .position(position) = target else { Issue.record("expected position"); return }
        var o = SidebarLayoutOptions()
        o.excludedWorkspaces = Set(ids.map(id))
        o.showEmptyPinned = true
        o.gap = position
        o.gapHeight = 40
        let displayed = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        let gapY = displayed.gapY!
        // Past the gap the pointer lands in G2's top edge zone, still "before G2".
        let edge = baseLayout.row(for: .group(g2))!.height * DropResolver.groupEdgeFraction * 0.8
        for displayY in stride(from: gapY - 10, through: gapY + displayed.gapShift + edge, by: 1) {
            guard let by = DropResolver.baseY(forDisplayY: displayY, gapY: displayed.gapY, gapHeight: displayed.gapShift) else { continue }
            let again = DropResolver.resolve(y: by, payload: .workspaces(ids.map(id)), base: baseLayout, sections: sections)
            // Just above the gap or just below it still names the same slot.
            #expect(again == target)
        }
    }

    @Test func resolvedTargetAppliesToExpectedOrder() {
        // Drag a onto the lower half of b; applying the target puts a after b.
        guard case let .position(position) = resolve(.workspace(id("b")), 0.8, dragging: ["a"]) else {
            Issue.record("expected position"); return
        }
        var s = sections
        SidebarEdits.apply(.reorder([id("a")], to: position), to: &s)
        #expect(shape(s, local) == "G1[g1,g2,g3] b a G2[h1,h2] c")
    }

    @Test func groupPayloadTreatsExpandedGroupAsBlock() {
        // Drag G2 over G1's rows: upper half of the block is before G1.
        let layout = base(group: g2)
        let top = layout.row(for: .group(g1))!.y
        let bottom = layout.row(for: .workspace(id("g3")))!.maxY
        let upper = DropResolver.resolve(y: top + (bottom - top) * 0.3, payload: .group(g2), base: layout, sections: sections)
        let lower = DropResolver.resolve(y: top + (bottom - top) * 0.7, payload: .group(g2), base: layout, sections: sections)
        #expect(upper == .position(DropPosition(section: local, index: 1)))
        #expect(lower == .position(DropPosition(section: local, index: 2)))
        // Groups never leave their machine section.
        let overCloud = DropResolver.resolve(y: y(.workspace(id("x")), 0.5, in: layout), payload: .group(g2), base: layout, sections: sections)
        #expect(overCloud == nil)
    }
}

// MARK: - Keyboard reorder

@Suite struct KeyboardReorderTests {
    @Test func stepsOverCollapsedGroupAndIntoExpandedGroup() {
        let s = fixture()
        #expect(KeyboardReorder.target(moving: [id("b")], direction: .down, in: s) == DropPosition(section: local, index: 3))
        #expect(KeyboardReorder.target(moving: [id("b")], direction: .up, in: s) == DropPosition(section: local, group: g1, index: 3))
    }

    @Test func leavesGroupFromFirstChild() {
        let s = fixture()
        #expect(KeyboardReorder.target(moving: [id("g1")], direction: .up, in: s) == DropPosition(section: local, index: 1))
    }

    @Test func stopsAtSectionBoundaries() {
        let s = fixture()
        #expect(KeyboardReorder.target(moving: [id("c")], direction: .down, in: s) == nil)
        #expect(KeyboardReorder.target(moving: [id("x")], direction: .up, in: s) == nil)
    }

    @Test func modelMoveSelectionAppliesLocally() {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("c"))
        #expect(model.moveSelection(.up))
        #expect(shape(model.sections, local) == "a G1[g1,g2,g3] b c G2[h1,h2]")
        model.filterText = "zzz"
        #expect(!model.moveSelection(.up))
    }
}

// MARK: - Selection

@Suite struct Selection {
    @Test func clickToggleAndExtend() {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let order = model.allWorkspaces.map(\.id)
        model.extendSelection(to: id("b"), visibleOrder: order)
        #expect(model.orderedSelection == ["a", "g1", "g2", "g3", "b"].map(id))
        model.toggleSelection(id("g2"))
        #expect(!model.selection.contains(id("g2")))
        model.click(id("c"))
        #expect(model.selection == [id("c")])
        #expect(model.activeWorkspaceID == id("c"))
    }

    @Test func intentsRouteToHandlerWhenSet() {
        let model = SidebarModel(sections: fixture())
        var received: [SidebarIntent] = []
        model.onIntent = { received.append($0) }
        model.send(.toggleCollapse(.group(g1)))
        #expect(received == [.toggleCollapse(.group(g1))])
        #expect(model.group(g1)?.isCollapsed == false)
    }

    @Test func closingActivePicksAnotherSelection() {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        model.selection = [id("a"), id("b")]
        model.apply(.close([id("a")]))
        #expect(model.activeWorkspaceID == id("b"))
    }

    @Test func mockHasFortyWorkspacesAcrossTwoMachines() {
        let model = SidebarMock.makeModel()
        #expect(model.allWorkspaces.count == 40)
        #expect(model.sections.compactMap(\.machine).count == 2)
    }
}
