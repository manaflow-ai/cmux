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

    /// A row dropped onto another forms the group at the target row (the
    /// drop's anchor), not at the first member in tree order.
    @Test func createGroupOntoARowFormsTheGroupAtTheTarget() {
        let rows = { SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                    nodes: ["a", "y", "b", "x"].map { .workspace(w($0)) }) }
        // y dragged down onto x: a, b, then the group where x was.
        var down = [rows()]
        SidebarEdits.apply(.createGroup(GroupID("N"), name: "", color: .grey, workspaces: [id("x"), id("y")], anchor: id("x")), to: &down)
        #expect(shape(down, local) == "a b N[y,x]")
        // x dragged up onto y: the group where y was.
        var up = [rows()]
        SidebarEdits.apply(.createGroup(GroupID("N"), name: "", color: .grey, workspaces: [id("y"), id("x")], anchor: id("y")), to: &up)
        #expect(shape(up, local) == "a N[y,x] b")
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
