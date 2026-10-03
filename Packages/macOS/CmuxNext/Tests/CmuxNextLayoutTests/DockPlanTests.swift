import Testing
@testable import CmuxNextLayout

/// "Dock Column" with no arguments (layout-model.md): docked mode, the edge
/// the column is nearer to (right unless it is the leftmost of several
/// scrolling columns), its width clamped to 25-40%, and a second run undocks.
@Suite struct DockPlanTests {
    private func screen(_ widths: [Double], sticky: [Int: StickyColumn] = [:]) -> LayoutScreen {
        LayoutScreen(id: ScreenID("s"), name: "s", layout: .columns(widths.enumerated().map { index, width in
            LayoutColumn(id: ColumnID("c\(index)"), width: width, root: .leaf(PaneID("p\(index)")), sticky: sticky[index])
        }))
    }

    private func plan(_ screen: LayoutScreen, _ column: String, edge: StickyEdge? = nil,
                      mode: StickyMode = .docked) -> DockPlan? {
        DockDefaults.plan(screen: screen, column: ColumnID(column), pane: nil, edge: edge, mode: mode)
    }

    @Test func aMiddleOrRightColumnDocksRightAtItsClampedWidth() {
        let s = screen([0.5, 0.2, 0.6])
        #expect(plan(s, "c1") == .pin("c1", StickyColumn(edge: .right, mode: .docked), width: 0.25))
        #expect(plan(s, "c2") == .pin("c2", StickyColumn(edge: .right, mode: .docked), width: 0.40))
    }

    @Test func theLeftmostColumnDocksLeft() {
        #expect(plan(screen([0.3, 0.5, 0.5]), "c0") == .pin("c0", StickyColumn(edge: .left, mode: .docked), width: 0.3))
    }

    @Test func aTakenDefaultEdgeYieldsToTheFreeSide() {
        let s = screen([0.5, 0.5, 0.3], sticky: [2: StickyColumn(edge: .right, mode: .docked)])
        #expect(plan(s, "c1") == .pin("c1", StickyColumn(edge: .left, mode: .docked), width: 0.40))
    }

    @Test func dockingADockedColumnAgainUndocksIt() {
        let s = screen([0.5, 0.5, 0.3], sticky: [2: StickyColumn(edge: .right, mode: .docked)])
        #expect(plan(s, "c2") == .undock("c2"))
        // An explicit other edge moves the dock instead.
        #expect(plan(s, "c2", edge: .top) == .pin("c2", StickyColumn(edge: .top, mode: .docked), width: 0.3))
    }

    @Test func floatingIsTheSameRuleInOverlayMode() {
        let s = screen([0.5, 0.5])
        #expect(plan(s, "c1", mode: .overlay) == .pin("c1", StickyColumn(edge: .right, mode: .overlay), width: 0.40))
        let floating = screen([0.5, 0.5], sticky: [1: StickyColumn(edge: .right, mode: .overlay)])
        #expect(plan(floating, "c1", mode: .overlay) == .undock("c1"))
        // Dock Column on a floating column docks it in place.
        #expect(plan(floating, "c1") == .pin("c1", StickyColumn(edge: .right, mode: .docked), width: 0.40))
    }

    @Test func aScreensOnlyColumnDocksItsTabIntoANewColumn() {
        let lone = LayoutScreen(id: ScreenID("s"), name: "s", layout: .splits(.leaf(PaneID("p0"))))
        let plan = DockDefaults.plan(screen: lone, column: lone.implicitColumnID, pane: PaneID("p0"), edge: nil, mode: .docked)
        #expect(plan == .moveTab("p0", StickyColumn(edge: .right, mode: .docked), width: 0.40))
        // The only scrolling column of a screen with a dock does the same.
        let s = screen([0.5, 0.3], sticky: [1: StickyColumn(edge: .right, mode: .docked)])
        #expect(DockDefaults.plan(screen: s, column: "c0", pane: "p0", edge: nil, mode: .docked)
                == .moveTab("p0", StickyColumn(edge: .left, mode: .docked), width: 0.40))
    }
}
