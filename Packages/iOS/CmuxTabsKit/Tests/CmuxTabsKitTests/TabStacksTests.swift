import CoreGraphics
import Testing
@testable import CmuxTabsKit

/// The grid's pane stacks (Aziz's drawing, 2026-11-23): which cards show folded and open, and
/// the encasement's rows.
struct TabStacksTests {
    /// The drawing: a pane of three (docs in front), a lone terminal, a lone page, a pane of two.
    let ids = ["docs", "zsh", "build", "server", "site", "tests", "logs"]
    func stack(_ id: String) -> TabsKitStack? {
        switch id {
        case "docs", "zsh", "build": TabsKitStack(id: "p1", title: "Pane 1", frontTabID: "docs")
        case "tests", "logs": TabsKitStack(id: "p4", title: "Pane 4", frontTabID: "tests")
        case "server": TabsKitStack(id: "p2", title: "Pane 2")
        default: nil
        }
    }

    @Test func foldedShowsTheDrawingsFourCards() {
        let plan = TabStackPlan(ids: ids, stack: stack, active: "docs", open: [])
        #expect(plan.visible == ["docs", "server", "site", "tests"])
        #expect(plan.stacks.map(\.id) == ["p1", "p4"])
        #expect(plan.stacks.map(\.anchor) == [0, 3])
        #expect(plan.stack(anchoredAt: 0)?.members == ["docs", "zsh", "build"])
        #expect(plan.stack(anchoredAt: 1) == nil)
        // A pane of one is no stack.
        #expect(plan.stack(of: "server") == nil)
    }

    @Test func openingTheFirstShowsSixCards() {
        let plan = TabStackPlan(ids: ids, stack: stack, active: "docs", open: ["p1"])
        #expect(plan.visible == ["docs", "zsh", "build", "server", "site", "tests"])
        #expect(plan.stacks.map(\.anchor) == [0, 5])
        #expect(plan.folded(plan.stacks[0]).isEmpty)
        #expect(plan.folded(plan.stacks[1]) == ["logs"])
    }

    @Test func theActiveTabFrontsItsFoldedStack() {
        let plan = TabStackPlan(ids: ids, stack: stack, active: "build", open: [])
        #expect(plan.visible == ["build", "server", "site", "tests"])
        #expect(plan.stacks[0].front == "build")
        // Not in a stack: the stack's own front tab.
        let other = TabStackPlan(ids: ids, stack: stack, active: "site", open: [])
        #expect(other.visible == ["docs", "server", "site", "tests"])
    }

    @Test func aStackGathersTabsListedApart() {
        let apart = ["docs", "server", "zsh", "site", "build"]
        let plan = TabStackPlan(ids: apart, stack: stack, active: "server", open: ["p1"])
        #expect(plan.visible == ["docs", "zsh", "build", "server", "site"])
        // A card dragged to grid slot 3 (server) maps to server's source index.
        #expect(plan.sourceIndex(forSlot: 3, ids: apart) == 1)
    }

    @Test func pinnedTabsNeverStack() {
        let plan = TabStackPlan(ids: ids, stack: stack, active: "zsh", open: [], pinned: ["docs"])
        #expect(plan.visible == ["docs", "zsh", "server", "site", "tests"])
        #expect(plan.stacks[0].members == ["zsh", "build"])
    }

    @Test func noStacksKeepsEveryTab() {
        let plan = TabStackPlan(ids: ids, stack: { _ in nil }, active: "docs", open: [])
        #expect(plan.visible == ids)
        #expect(plan.stacks.isEmpty)
    }

    // MARK: Encasement rows

    let layout = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 6)

    @Test func oneCardIsOneRect() {
        let r = StackOutlineRects.make(layout: layout, first: 0, count: 1, pad: 6)
        #expect(r.a == r.b && r.b == r.c)
        let card = layout.card(0)
        #expect(r.a.minX == card.minX - 6 && r.a.minY == card.minY - 6)
        #expect(r.a.height == card.height + OverviewLayout.titleRow + 2 + 12)
    }

    @Test func theDrawingsLIsTwoRowsBridged() {
        // Slots 0, 1 (first row) and 2 (second row, left): the drawing's L.
        let r = StackOutlineRects.make(layout: layout, first: 0, count: 3, pad: 6)
        #expect(r.a.minX == layout.card(0).minX - 6 && r.a.maxX == layout.card(1).maxX + 6)
        #expect(r.b == r.c && r.b.maxX == layout.card(2).maxX + 6)
        let pieces = r.pieces(maxGap: OverviewLayout.rowGap + 2)
        // One bridge across the row gap, as wide as the left column.
        #expect(pieces.rows.count == 2)
        #expect(pieces.bridges.count == 1)
        #expect(abs(pieces.bridges[0].width - r.c.width) < 0.01)
        // Reaching the rows' corner radius into each row, it squares the
        // corners on the shared edge: the L's left side is one straight line.
        let reach = r.pieces(maxGap: OverviewLayout.rowGap + 2, overlap: 20).bridges[0]
        #expect(abs(reach.minY - (r.a.maxY - 20)) < 0.01)
        #expect(abs(reach.maxY - (r.c.minY + 20)) < 0.01)
        #expect(abs(reach.minX - r.c.minX) < 0.01)
    }

    @Test func threeRowsKeepTheMiddleWhole() {
        let tall = OverviewLayout(size: layout.size, safeTop: 62, safeBottom: 34, count: 9)
        let r = StackOutlineRects.make(layout: tall, first: 1, count: 6, pad: 6)
        // Row 0: slot 1; rows 1-2: slots 2-5; row 3: slot 6.
        #expect(r.a.minX == tall.card(1).minX - 6)
        #expect(r.b.minY == tall.card(2).minY - 6 && r.b.maxY == tall.card(5).maxY + OverviewLayout.titleRow + 2 + 6)
        #expect(r.c.maxX == tall.card(6).maxX + 6)
    }
}
