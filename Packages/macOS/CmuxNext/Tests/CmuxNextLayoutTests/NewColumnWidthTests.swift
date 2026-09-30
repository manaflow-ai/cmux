import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Width of a new column and the lone full-width column rule
/// (plans/cmux-next/niri.md, "Column widths").
@Suite struct NewColumnWidthTests {
    private func lone(_ width: Double) -> [LayoutColumn] {
        [LayoutColumn(id: "c0", width: width, root: .leaf("p0"))]
    }

    @Test func builtInDefaultIsHalfTheViewportLikeNiri() {
        // niri-config `Layout::default()`: default_column_width Proportion(0.5).
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

    @Test func otherLayoutsKeepTheirWidthsLikeNiri() {
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
        let recorder = Recorder()
        model.intentHandler = { recorder.intents.append($0) }
        return (model, recorder)
    }

    @Test func newColumnNextToALoneFullColumnShrinksItOptimistically() throws {
        let (model, recorder) = makeModel([LayoutColumn(id: "c0", width: 1.0, root: .leaf("p0"))])
        model.newColumn()
        #expect(model.screens[0].layout.columns.first?.width == 0.5)
        #expect(recorder.intents.count == 2)
        guard case let .setColumnWidth(column, anyPane, width, _, phase) = recorder.intents.first else {
            Issue.record("expected the width intent first, got \(recorder.intents)")
            return
        }
        #expect(column == "c0" && anyPane == "p0" && width == 0.5 && phase == .ended)
        #expect(recorder.intents.last == .newColumn(after: "p0", width: 0.5))
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
        #expect(model.prepareNewColumn(nextTo: "p0") == 0.5)
        #expect(recorder.intents.count == 1)
        #expect(model.prepareNewColumn(nextTo: "missing") == 0.5)
        #expect(recorder.intents.count == 1)
    }

    @Test func followsTheDesignSettingWithoutAnOverride() {
        let (model, _) = makeModel([])
        model.defaultColumnWidthOverride = nil
        model.followsDesignMetrics = false
        #expect(model.defaultColumnWidth == ColumnWidthPreset.defaultWidth)
        model.followsDesignMetrics = true
        #expect(model.defaultColumnWidth == DesignSettings.shared.defaultColumnWidth)
    }
}
