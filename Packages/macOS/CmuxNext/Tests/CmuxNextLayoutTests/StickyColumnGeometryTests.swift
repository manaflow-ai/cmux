import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Viewport math for a sticky column on each edge in each mode
/// (plans/cmux-next/sticky-column.md, S1 to S6). Default style: gap 6,
/// no pane padding, 1000 x 600 viewport, scale 2.
@Suite struct StickyColumnGeometryTests {
    let viewport = CGSize(width: 1000, height: 600)
    let style = LayoutStyle()

    private func columns(_ sticky: StickyColumn?, stickyIndex: Int, widths: [Double] = [0.5, 0.5, 0.3]) -> ScreenLayout {
        .columns(widths.enumerated().map { index, width in
            LayoutColumn(id: ColumnID("c\(index)"), width: width, root: .leaf(PaneID("p\(index)")),
                         sticky: index == stickyIndex ? sticky : nil)
        })
    }

    private func geometry(_ layout: ScreenLayout) -> ScreenGeometry {
        ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    @Test func rightDockedShrinksTheStripAndNeverScrolls() {
        let g = geometry(columns(StickyColumn(edge: .right, mode: .docked), stickyIndex: 2))
        // (1000 - 6) * 0.3 - 6 = 292.2, rounded to the pixel: 292.
        let frame = CGRect(x: 702, y: 0, width: 292, height: 600)
        #expect(g.sticky.map(\.frame) == [frame])
        #expect(g.panes["p2"] == frame)
        #expect(g.fixedPanes == ["p2"])
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 702)
        #expect(g.columnOrder == ["c0", "c1"])
        // Two half columns of a 702 pt strip fill it: nothing to scroll.
        #expect(g.panes["p0"] == CGRect(x: 6, y: 0, width: 342, height: 600))
        #expect(g.maxOffset == 0)
        #expect(g.uncoveredMaxX == 702)
        #expect(g.sticky.first?.cover == CGRect(x: 702, y: 0, width: 298, height: 600))
    }

    @Test func leftDockedMovesTheStripOriginPastTheColumn() {
        let g = geometry(columns(StickyColumn(edge: .left, mode: .docked), stickyIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(g.sticky.map(\.frame) == [CGRect(x: 6, y: 0, width: 292, height: 600)])
        #expect(g.stripMinX == 298)
        #expect(g.stripWidth == 702)
        // Strip panes stay in strip space; the view adds stripMinX - offset.
        #expect(g.panes["p1"]?.minX == 6)
        #expect(g.viewShift(offset: 0) == 298)
        #expect(g.uncoveredMinX == 298)
    }

    @Test func rightOverlayKeepsTheFullWidthAndAddsATrailingInset() {
        let g = geometry(columns(StickyColumn(edge: .right, mode: .overlay), stickyIndex: 2))
        #expect(g.sticky.map(\.frame) == [CGRect(x: 702, y: 0, width: 292, height: 600)])
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 1000)
        // Columns are halves of the whole viewport: (1000 - 6) * 0.5 - 6.
        #expect(g.panes["p0"] == CGRect(x: 6, y: 0, width: 491, height: 600))
        #expect(g.panes["p1"] == CGRect(x: 503, y: 0, width: 491, height: 600))
        // The last column can scroll out from under the overlay.
        #expect(abs(g.contentWidth - 1298) < 0.01)
        #expect(abs(g.maxOffset - 298) < 0.01)
        #expect(g.sticky.first?.cover == CGRect(x: 699, y: 0, width: 301, height: 600))
        #expect(g.sticky.first?.glass == CGRect(x: 699, y: 0, width: 298, height: 600))
        #expect(g.clipMaxX == 997)
        #expect(g.uncoveredMaxX == 699)
    }

    @Test func leftOverlayAddsALeadingInsetSoTheFirstColumnRestsBesideIt() {
        let g = geometry(columns(StickyColumn(edge: .left, mode: .overlay), stickyIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(g.stripMinX == 0)
        #expect(g.stripWidth == 1000)
        #expect(g.panes["p1"]?.minX == 304)
        #expect(abs(g.maxOffset - 298) < 0.01)
        #expect(g.uncoveredMinX == 301)
        #expect(g.gapZones.first?.frame.midX == 301)
    }

    @Test func onlyTheFirstStickyColumnPerEdgeHoldsIt() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")),
            LayoutColumn(id: "b", width: 0.3, root: .leaf("pb"), sticky: StickyColumn(edge: .right)),
            LayoutColumn(id: "c", width: 0.3, root: .leaf("pc"), sticky: StickyColumn(edge: .right)),
        ])
        let g = geometry(layout)
        #expect(g.sticky.map(\.column) == ["b"])
        #expect(g.columnOrder == ["a", "c"])
    }

    @Test func aScreenOfOnlyStickyColumnsScrollsThemAll() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa"), sticky: StickyColumn(edge: .left)),
            LayoutColumn(id: "b", width: 0.5, root: .leaf("pb"), sticky: StickyColumn(edge: .right)),
        ])
        let g = geometry(layout)
        #expect(g.sticky.isEmpty)
        #expect(g.columnOrder == ["a", "b"])
        #expect(g.fixedPanes.isEmpty)
    }

    @Test func stickyWidthIsCappedSoTheStripKeepsRoom() {
        let wide = geometry(columns(StickyColumn(edge: .right), stickyIndex: 2, widths: [0.5, 0.5, 1.0]))
        #expect(wide.sticky.first?.frame.width == 750)
        let both = ScreenLayout.columns([
            LayoutColumn(id: "l", width: 1.0, root: .leaf("pl"), sticky: StickyColumn(edge: .left)),
            LayoutColumn(id: "m", width: 0.5, root: .leaf("pm")),
            LayoutColumn(id: "r", width: 1.0, root: .leaf("pr"), sticky: StickyColumn(edge: .right)),
        ])
        let g = geometry(both)
        #expect(g.sticky.map(\.frame.width) == [400, 400])
        #expect(g.stripMinX == 406)
        #expect(g.stripWidth == 188)
    }

    @Test func aStickyColumnsResizeHandleIsOnItsInnerEdge() {
        // On the column's own edge, so the gap keeps the strip column's handle.
        let right = geometry(columns(StickyColumn(edge: .right), stickyIndex: 2))
        let handle = right.columnEdges.first { $0.column == "c2" }
        #expect(handle?.stickyEdge == .right)
        #expect(handle?.hitFrame.midX == 704.5)
        let left = geometry(columns(StickyColumn(edge: .left), stickyIndex: 0, widths: [0.3, 0.5, 0.5]))
        #expect(left.columnEdges.first { $0.column == "c0" }?.hitFrame.midX == 295.5)
    }

    @Test func theScrollReducerSeesOnlyTheScrollingColumns() {
        let layout = columns(StickyColumn(edge: .right), stickyIndex: 3, widths: [0.5, 0.5, 0.5, 0.3])
        let g = geometry(layout)
        let strip = ColumnStrip(layout: layout, geometry: g, gap: style.stripGap)
        #expect(strip?.columns.map(\.id) == ["c0", "c1", "c2"])
        #expect(strip?.viewportWidth == 702)
        #expect((strip?.maxOffset ?? 0) > 0)
        #expect(strip?.maxOffset == g.maxOffset)
    }
}

/// Model rules the app applies optimistically, matching the daemon's.
@Suite struct StickyColumnModelTests {
    @Test func makingAColumnStickyFreesTheOldColumnOnThatEdge() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa"), sticky: StickyColumn(edge: .right)),
            LayoutColumn(id: "b", root: .leaf("pb")),
            LayoutColumn(id: "c", root: .leaf("pc"), sticky: StickyColumn(edge: .left)),
        ])
        let next = layout.settingSticky(StickyColumn(edge: .right, mode: .overlay), for: "b")
        #expect(next.columns.map(\.sticky) == [nil, StickyColumn(edge: .right, mode: .overlay), StickyColumn(edge: .left)])
        #expect(next.settingSticky(nil, for: "b").columns.map(\.sticky) == [nil, nil, StickyColumn(edge: .left)])
    }

    @Test func stickinessIsStructureAndWidthsKeepIt() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa")), LayoutColumn(id: "b", root: .leaf("pb")),
        ])
        let sticky = layout.settingSticky(StickyColumn(), for: "b")
        #expect(!layout.hasSameStructure(as: sticky))
        #expect(sticky.settingWidth(0.3, for: "b").columns.last?.sticky == StickyColumn())
    }
}

/// Column focus moves in the order the user sees: left sticky, strip, right sticky.
@Suite struct StickyColumnVisualOrderTests {
    @Test func stickyColumnsSitAtTheirEdgesWhateverTheirDaemonIndex() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "a", root: .leaf("pa")),
            LayoutColumn(id: "r", root: .leaf("pr"), sticky: StickyColumn(edge: .right)),
            LayoutColumn(id: "b", root: .leaf("pb")),
            LayoutColumn(id: "l", root: .leaf("pl"), sticky: StickyColumn(edge: .left)),
        ])
        #expect(layout.visualColumns.map(\.id) == ["l", "a", "b", "r"])
    }
}

/// The daemon owns the flag (OWNERSHIP-PRINCIPLES.md): the model validates
/// and emits the intent, and changes nothing until the snapshot carries it.
@MainActor
@Suite struct StickyColumnIntentTests {
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
        #expect(model.setColumnSticky("b", StickyColumn(edge: .right, mode: .overlay)) == nil)
        #expect(model.screens == before)
        guard case let .setColumnSticky(column, anyPane, sticky, _)? = intents.first else {
            Issue.record("no intent")
            return
        }
        #expect(column == "b" && anyPane == "pb" && sticky == StickyColumn(edge: .right, mode: .overlay))
    }

    @Test func refusesWhatTheDaemonWouldRefuse() {
        let model = model()
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        #expect(model.setColumnSticky("b", nil) == .unchanged)
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "a", root: .leaf("pa"), sticky: StickyColumn(edge: .left)), LayoutColumn(id: "b", root: .leaf("pb")),
        ]))])
        #expect(model.setColumnSticky("b", StickyColumn(edge: .right)) == .lastScrollingColumn)
        #expect(model.setColumnSticky("zz", StickyColumn()) == .unknownColumn)
        #expect(intents.isEmpty)
    }
}
