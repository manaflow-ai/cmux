import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Width of a new column and the lone full-width column rule
/// (plans/cmux-next/column-scroll.md, "Column widths").
@Suite struct NewColumnWidthTests {
    private func lone(_ width: Double) -> [LayoutColumn] {
        [LayoutColumn(id: "c0", width: width, root: .leaf("p0"))]
    }

    @Test func builtInDefaultIsHalfTheViewport() {
        #expect(ColumnWidthPreset.defaultWidth == 0.5)
        #expect(LayoutColumn(id: "c", root: .leaf("p")).width == 0.5)
    }

    @Test func aLoneFullWidthColumnShrinksSoBothColumnsFit() {
        let plan = NewColumnWidth.plan(columns: lone(1.0), width: 0.5)
        #expect(plan.width == 0.5)
        #expect(plan.resize == ColumnResize(column: "c0", width: 0.5))
    }

    @Test func theLoneColumnTakesTheRestOfAConfiguredWidth() {
        let third = NewColumnWidth.plan(columns: lone(1.0), width: 1.0 / 3.0)
        #expect(abs((third.resize?.width ?? 0) - 2.0 / 3.0) < 1e-9)
        let twoThirds = NewColumnWidth.plan(columns: lone(1.0), width: 2.0 / 3.0)
        #expect(abs((twoThirds.resize?.width ?? 0) - 1.0 / 3.0) < 1e-9)
    }

    @Test func otherLayoutsKeepTheirWidths() {
        #expect(NewColumnWidth.plan(columns: lone(0.5), width: 0.5).resize == nil)
        #expect(NewColumnWidth.plan(columns: lone(2.0 / 3.0), width: 0.5).resize == nil)
        let two = [LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))]
        #expect(NewColumnWidth.plan(columns: two, width: 0.5).resize == nil)
        #expect(NewColumnWidth.plan(columns: [], width: 0.5).resize == nil)
    }

    @Test func aFullWidthNewColumnCannotShareTheViewport() {
        let plan = NewColumnWidth.plan(columns: lone(1.0), width: 1.0)
        #expect(plan.width == 1.0)
        #expect(plan.resize == nil)
    }

    @Test func noResizeWhenTheLoneColumnGoesAway() {
        // Dragging the lone column's only pane out empties that column.
        #expect(NewColumnWidth.plan(columns: lone(1.0), width: 0.5, removing: "p0").resize == nil)
        let split = [LayoutColumn(id: "c0", width: 1.0, root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1")))]
        #expect(NewColumnWidth.plan(columns: split, width: 0.5, removing: "p0").resize == ColumnResize(column: "c0", width: 0.5))
    }

    @Test func widthsOutsideTheDaemonRangeAreClamped() {
        #expect(NewColumnWidth.plan(columns: [], width: 0.01).width == 0.1)
        #expect(NewColumnWidth.plan(columns: [], width: 3).width == 1.0)
    }

    /// The reported bug: after the second column opened, the view scrolled so
    /// only the first column's empty right third showed. With the plan
    /// applied both columns are fully visible and the camera stays at 0.
    @Test func bothColumnsAreFullyVisibleAfterTheSecondOpens() {
        let viewport: CGFloat = 1200, gap: CGFloat = 8
        func strip(_ widths: [Double]) -> ColumnStrip {
            makeStrip(widths.map { ColumnStripGeometry.pixelWidth(fraction: $0, viewportWidth: viewport, gap: gap) },
                      viewport: viewport, gap: gap)
        }
        var state = settledState(strip([1.0]), focused: "p0")
        let plan = NewColumnWidth.plan(columns: lone(1.0), width: ColumnWidthPreset.defaultWidth)
        let after = strip([plan.resize?.width ?? 1.0, plan.width])
        state.reduce(.sync(after, focused: PaneID("p1"), source: .programmatic, animated: true))
        state.runToRest()
        #expect(state.spring.value == 0)
        for column in after.columns {
            #expect(column.frame.minX - state.spring.value >= 0)
            #expect(column.frame.maxX - state.spring.value <= viewport)
        }
    }
}

@Suite @MainActor struct LayoutModelNewColumnTests {
    final class Recorder { var intents: [LayoutIntent] = [] }

    private func makeModel(_ columns: [LayoutColumn]) -> (LayoutModel, Recorder) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns(columns))])
        model.defaultColumnWidthOverride = 0.5
        model.newColumnWidthModeOverride = .fixed
        let recorder = Recorder()
        model.intentHandler = { recorder.intents.append($0) }
        return (model, recorder)
    }

    /// cmux-tui keeps a lone column as a leaf root (no viewport) and refuses
    /// a viewport width for it, so the width change must wait until the new
    /// column exists. Sent first, it was refused and the first column stayed
    /// full width, scrolled off screen (seen live on tag nxset).
    @Test func newColumnSendsNoWidthBeforeTheNewColumnExists() {
        let (model, recorder) = makeModel([LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0"))])
        model.newColumn()
        #expect(recorder.intents == [.newColumn(after: "p0", width: 0.5)])
        #expect(model.screens[0].layout.columns.first?.width == 1.0)
    }

    @Test func commitShrinksTheLoneColumnOptimisticallyAfterward() throws {
        let (model, recorder) = makeModel([LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0"))])
        let request = model.prepareNewColumn(nextTo: "p0")
        #expect(request.width == 0.5)
        #expect(recorder.intents.isEmpty)
        model.commitNewColumnResize(request)
        #expect(model.screens[0].layout.columns.first?.width == 0.5)
        guard case let .setColumnWidth(column, anyPane, width, _, phase)? = recorder.intents.first, recorder.intents.count == 1 else {
            Issue.record("expected one width intent, got \(recorder.intents)")
            return
        }
        #expect(column == "c0" && anyPane == "p0" && width == 0.5 && phase == .ended)
    }

    @Test func newColumnUsesTheConfiguredWidthAndKeepsOtherColumns() {
        let (model, recorder) = makeModel([
            LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0")),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
        ])
        model.defaultColumnWidthOverride = 1.0 / 3.0
        model.newColumn(after: "p1")
        #expect(recorder.intents == [.newColumn(after: "p1", width: 1.0 / 3.0)])
        #expect(model.screens[0].layout.columns.map(\.width) == [1.0, 0.5])
    }

    @Test func prepareReturnsTheWidthForOtherNewColumnPaths() {
        let (model, recorder) = makeModel([LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0"))])
        #expect(model.prepareNewColumn(nextTo: "p0").width == 0.5)
        #expect(model.prepareNewColumn(nextTo: "missing").width == 0.5)
        #expect(recorder.intents.isEmpty)
    }

    @Test func followsTheDesignSettingWithoutAnOverride() {
        let (model, _) = makeModel([])
        model.defaultColumnWidthOverride = nil
        model.followsDesignMetrics = false
        #expect(model.defaultColumnWidth == ColumnWidthPreset.defaultWidth)
        model.followsDesignMetrics = true
        #expect(model.defaultColumnWidth == DesignSettings.shared.defaultColumnWidth)
    }

    /// A workspace that never had a second column mirrors as a split tree
    /// (the daemon root is a leaf, not a viewport). The live app only ever
    /// sees this shape for "one full-width column", so the rule must cover it.
    @Test func aSplitTreeScreenCountsAsALoneFullColumn() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("p0")))])
        model.defaultColumnWidthOverride = 0.5
        model.newColumnWidthModeOverride = .fixed
        let recorder = Recorder()
        model.intentHandler = { recorder.intents.append($0) }
        model.newColumn()
        #expect(recorder.intents == [.newColumn(after: "p0", width: 0.5)])
        model.commitNewColumnResize(model.prepareNewColumn(nextTo: "p0"))
        guard case let .setColumnWidth(_, anyPane, width, _, phase)? = recorder.intents.last, recorder.intents.count == 2 else {
            Issue.record("expected a width intent after the new column, got \(recorder.intents)")
            return
        }
        #expect(anyPane == "p0" && width == 0.5 && phase == .ended)
    }
}

/// The default mode: a new column matches the current one and nothing
/// resizes (user decision, plans/cmux-next/column-sizing.md).
@Suite @MainActor struct LayoutModelMatchCurrentTests {
    @Test func aNewColumnMatchesTheCurrentWidthAndSendsNoResize() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0")), LayoutColumn(id: "c1", width: 0.4, root: .leaf("p1")),
        ]))])
        model.followsDesignMetrics = false
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        #expect(model.newColumnWidthMode == .matchCurrent)
        model.newColumn(after: "p1")
        #expect(intents == [.newColumn(after: "p1", width: 0.4)])
        model.commitNewColumnResize(model.prepareNewColumn(nextTo: "p1"))
        #expect(intents.count == 1)
    }

    @Test func anUnscrolledScreenOpensAFullWidthColumn() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("p0")))])
        model.followsDesignMetrics = false
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        model.newColumn()
        #expect(intents == [.newColumn(after: "p0", width: 1.0)])
    }
}
