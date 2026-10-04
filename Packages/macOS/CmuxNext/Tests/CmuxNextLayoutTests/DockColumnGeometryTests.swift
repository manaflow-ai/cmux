import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Viewport math for a docked column on each edge in each mode
/// (plans/cmux-next/dock-column.md, S1 to S6). Default style: gap 6,
/// no pane padding, 1000 x 600 viewport, scale 2.
@Suite struct DockColumnGeometryTests {
    let viewport = CGSize(width: 1000, height: 600)
    let style = LayoutStyle()

    private func columns(_ dock: DockColumn?, dockIndex: Int, widths: [Double] = [0.5, 0.5, 0.3]) -> ScreenLayout {
        .columns(widths.enumerated().map { index, width in
            LayoutColumn(id: ColumnID("c\(index)"), width: width, root: .leaf(PaneID("p\(index)")),
                         dock: index == dockIndex ? dock : nil)
        })
    }

    private func geometry(_ layout: ScreenLayout) -> ScreenGeometry {
        ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    @Test func rightDockedShrinksTheStripAndNeverScrolls() {
        let g = geometry(columns(DockColumn(edge: .right, mode: .docked), dockIndex: 2))
        // (1000 - 6) * 0.3 - 6 = 292.2, rounded to the pixel: 292.
        let frame = CGRect(x: 702, y: 0, width: 292, height: 600)
        #expect(g.dock.map(\.frame) == [frame])
        #expect(g.panes["p2"] == frame)
        #expect(g.fixedPanes == ["p2"])
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 702)
        #expect(g.columnOrder == ["c0", "c1"])
        // Two half columns of a 702 pt strip fill it: nothing to scroll.
        #expect(g.panes["p0"] == CGRect(x: 6, y: 0, width: 342, height: 600))
        #expect(g.maxOffset == 0)
        #expect(g.uncoveredMaxX == 702)
        #expect(g.dock.first?.cover == CGRect(x: 702, y: 0, width: 298, height: 600))
    }

    @Test func leftDockedMovesTheStripOriginPastTheColumn() {
        let g = geometry(columns(DockColumn(edge: .left, mode: .docked), dockIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(g.dock.map(\.frame) == [CGRect(x: 6, y: 0, width: 292, height: 600)])
        #expect(g.stripMinX == 298)
        #expect(g.stripWidth == 702)
        // Strip panes stay in strip space; the view adds stripMinX - offset.
        #expect(g.panes["p1"]?.minX == 6)
        #expect(g.viewShift(offset: 0) == 298)
        #expect(g.uncoveredMinX == 298)
    }

    @Test func rightOverlayKeepsTheFullWidthAndAddsATrailingInset() {
        let g = geometry(columns(DockColumn(edge: .right, mode: .overlay), dockIndex: 2))
        #expect(g.dock.map(\.frame) == [CGRect(x: 702, y: 0, width: 292, height: 600)])
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 1000)
        // Columns are halves of the whole viewport: (1000 - 6) * 0.5 - 6.
        #expect(g.panes["p0"] == CGRect(x: 6, y: 0, width: 491, height: 600))
        #expect(g.panes["p1"] == CGRect(x: 503, y: 0, width: 491, height: 600))
        // The last column can scroll out from under the overlay.
        #expect(abs(g.contentWidth - 1298) < 0.01)
        #expect(abs(g.maxOffset - 298) < 0.01)
        #expect(g.dock.first?.cover == CGRect(x: 699, y: 0, width: 301, height: 600))
        #expect(g.dock.first?.glass == CGRect(x: 699, y: 0, width: 298, height: 600))
        #expect(g.clipMaxX == 997)
        #expect(g.uncoveredMaxX == 699)
    }

    @Test func leftOverlayAddsALeadingInsetSoTheFirstColumnRestsBesideIt() {
        let g = geometry(columns(DockColumn(edge: .left, mode: .overlay), dockIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 1000)
        #expect(g.panes["p1"]?.minX == 304)
        #expect(abs(g.maxOffset - 298) < 0.01)
        #expect(g.uncoveredMinX == 301)
        #expect(g.gapZones.first?.frame.midX == 301)
    }

    @Test func onlyTheFirstDockColumnPerEdgeHoldsIt() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")),
            LayoutColumn(id: "b", width: 0.3, root: .leaf("pb"), dock: DockColumn(edge: .right)),
            LayoutColumn(id: "c", width: 0.3, root: .leaf("pc"), dock: DockColumn(edge: .right)),
        ])
        let g = geometry(layout)
        #expect(g.dock.map(\.column) == ["b"])
        #expect(g.columnOrder == ["a", "c"])
    }

    @Test func aScreenOfOnlyDockColumnsScrollsThemAll() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa"), dock: DockColumn(edge: .left)),
            LayoutColumn(id: "b", width: 0.5, root: .leaf("pb"), dock: DockColumn(edge: .right)),
        ])
        let g = geometry(layout)
        #expect(g.dock.isEmpty)
        #expect(g.columnOrder == ["a", "b"])
        #expect(g.fixedPanes.isEmpty)
    }

    @Test func dockWidthIsCappedSoTheStripKeepsRoom() {
        let wide = geometry(columns(DockColumn(edge: .right), dockIndex: 2, widths: [0.5, 0.5, 1.0]))
        // The 75% cap, then the minimum strip (400 pt of 1000) wins: 1000 - 400 - 6.
        #expect(wide.dock.first?.frame.width == 594)
        let both = ScreenLayout.columns([
            LayoutColumn(id: "l", width: 1.0, root: .leaf("pl"), dock: DockColumn(edge: .left)),
            LayoutColumn(id: "m", width: 0.5, root: .leaf("pm")),
            LayoutColumn(id: "r", width: 1.0, root: .leaf("pr"), dock: DockColumn(edge: .right)),
        ])
        let g = geometry(both)
        // Two 40% docks shrink alike so the strip keeps 400 pt: (1000 - 400 - 12) / 2.
        #expect(g.dock.map(\.frame.width) == [294, 294])
        #expect(g.stripMinX == 300)
        #expect(g.stripWidth == 400)
    }

    @Test func aDockColumnsResizeHandleIsOnItsInnerEdge() {
        // On the column's own edge, so the gap keeps the strip column's handle.
        let right = geometry(columns(DockColumn(edge: .right), dockIndex: 2))
        let handle = right.columnEdges.first { $0.column == "c2" }
        #expect(handle?.dockEdge == .right)
        #expect(handle?.hitFrame.midX == 704.5)
        let left = geometry(columns(DockColumn(edge: .left), dockIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(left.columnEdges.first { $0.column == "c0" }?.hitFrame.midX == 295.5)
    }

    @Test func theScrollReducerSeesOnlyTheScrollingColumns() {
        let layout = columns(DockColumn(edge: .right), dockIndex: 3, widths: [0.5, 0.5, 0.5, 0.3])
        let g = geometry(layout)
        let strip = ColumnStrip(layout: layout, geometry: g, gap: style.stripGap)
        #expect(strip?.columns.map(\.id) == ["c0", "c1", "c2"])
        #expect(strip?.viewportWidth == 702)
        #expect((strip?.maxOffset ?? 0) > 0)
        #expect(strip?.maxOffset == g.maxOffset)
    }
}

/// Model rules the app applies optimistically, matching the daemon's.
@Suite struct DockColumnModelTests {
    @Test func dockingAColumnFreesTheOldColumnOnThatEdge() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa"), dock: DockColumn(edge: .right)),
            LayoutColumn(id: "b", root: .leaf("pb")),
            LayoutColumn(id: "c", root: .leaf("pc"), dock: DockColumn(edge: .left)),
        ])
        let next = layout.settingDock(DockColumn(edge: .right, mode: .overlay), for: "b")
        #expect(next.columns.map(\.dock) == [nil, DockColumn(edge: .right, mode: .overlay), DockColumn(edge: .left)])
        #expect(next.settingDock(nil, for: "b").columns.map(\.dock) == [nil, nil, DockColumn(edge: .left)])
    }

    @Test func dockingIsStructureAndWidthsKeepIt() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa")), LayoutColumn(id: "b", root: .leaf("pb")),
        ])
        let dock = layout.settingDock(DockColumn(), for: "b")
        #expect(!layout.hasSameStructure(as: dock))
        #expect(dock.settingWidth(0.3, for: "b").columns.last?.dock == DockColumn())
    }
}

/// Column focus moves in the order the user sees: left docked, strip, right docked.
@Suite struct DockColumnVisualOrderTests {
    @Test func dockColumnsSitAtTheirEdgesWhateverTheirDaemonIndex() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa")),
            LayoutColumn(id: "r", root: .leaf("pr"), dock: DockColumn(edge: .right)),
            LayoutColumn(id: "b", root: .leaf("pb")),
            LayoutColumn(id: "l", root: .leaf("pl"), dock: DockColumn(edge: .left)),
        ])
        #expect(layout.visualColumns.map(\.id) == ["l", "a", "b", "r"])
    }
}

/// The daemon owns the flag (OWNERSHIP-PRINCIPLES.md): the model validates
/// and emits the intent, and changes nothing until the snapshot carries it.
@MainActor
@Suite struct DockColumnIntentTests {
    private func model() -> LayoutModel {
        LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "a", root: .leaf("pa")), LayoutColumn(id: "b", root: .leaf("pb")),
        ]))], activeScreenID: "s", focusedPane: "pa")
    }

    @Test func emitsTheIntentWithoutAnOptimisticCopy() {
        let model = model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        let before = model.screens
        #expect(model.setColumnDock("b", DockColumn(edge: .right, mode: .overlay)) == nil)
        #expect(model.screens == before)
        guard case let .setColumnDock(column, anyPane, dock, _)? = intents.first else {
            Issue.record("no intent")
            return
        }
        #expect(column == "b" && anyPane == "pb" && dock == DockColumn(edge: .right, mode: .overlay))
    }

    @Test func refusesWhatTheDaemonWouldRefuse() {
        let model = model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        #expect(model.setColumnDock("b", nil) == .unchanged)
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "a", root: .leaf("pa"), dock: DockColumn(edge: .left)), LayoutColumn(id: "b", root: .leaf("pb")),
        ]))])
        #expect(model.setColumnDock("b", DockColumn(edge: .right)) == .lastScrollingColumn)
        #expect(model.setColumnDock("zz", DockColumn()) == .unknownColumn)
        #expect(intents.isEmpty)
    }
}
