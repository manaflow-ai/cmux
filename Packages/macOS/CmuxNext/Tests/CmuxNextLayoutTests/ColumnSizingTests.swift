import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// `layout.newColumnWidth` (plans/cmux-next/column-sizing.md).
@Suite struct NewColumnWidthModeTests {
    private let columns = [
        LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")),
        LayoutColumn(id: "b", width: 0.3, root: .leaf("pb")),
        LayoutColumn(id: "c", width: 0.7, root: .leaf("pc")),
        LayoutColumn(id: "s", width: 0.25, root: .leaf("ps"), dock: DockColumn()),
    ]

    @Test func matchCurrentTakesTheAnchorWidthAndResizesNothing() {
        let plan = NewColumnWidth.plan(mode: .matchCurrent, columns: columns, anchor: "b", visible: ["a", "b"], fixedWidth: 0.5)
        #expect(plan.width == 0.3)
        #expect(plan.resizes.isEmpty)
    }

    @Test func matchCurrentOnAnUnscrolledScreenIsFullWidth() {
        let lone = [LayoutColumn(id: "x", width: 1.0, root: .leaf("p"))]
        let plan = NewColumnWidth.plan(mode: .matchCurrent, columns: lone, anchor: "x", visible: ["x"], fixedWidth: 0.5)
        #expect(plan.width == 1.0)
        #expect(plan.resizes.isEmpty)
    }

    @Test func fixedKeepsTheLoneColumnRule() {
        let lone = [LayoutColumn(id: "x", width: 1.0, root: .leaf("p"))]
        let plan = NewColumnWidth.plan(mode: .fixed, columns: lone, anchor: "x", visible: ["x"], fixedWidth: 0.5)
        #expect(plan == NewColumnWidth.plan(columns: lone, width: 0.5))
        let other = NewColumnWidth.plan(mode: .fixed, columns: columns, anchor: "a", visible: ["a", "b"], fixedWidth: 0.4)
        #expect(other.width == 0.4 && other.resizes.isEmpty)
    }

    @Test func fitScreenSharesTheStripWithTheVisibleColumns() {
        let plan = NewColumnWidth.plan(mode: .fitScreen, columns: columns, anchor: "b", visible: ["a", "b"], fixedWidth: 0.5)
        #expect(abs(plan.width - 1.0 / 3.0) < 1e-9)
        #expect(plan.resizes.map(\.column) == ["a", "b"])
        #expect(plan.resizes.allSatisfy { abs($0.width - 1.0 / 3.0) < 1e-9 })
    }

    @Test func fitScreenCountsTheAnchorAndNeverResizesDockColumns() {
        let plan = NewColumnWidth.plan(mode: .fitScreen, columns: columns, anchor: "c", visible: ["a", "s"], fixedWidth: 0.5)
        #expect(abs(plan.width - 1.0 / 3.0) < 1e-9)
        #expect(plan.resizes.map(\.column) == ["a", "c"])
    }

    @Test func fitScreenStaysInTheDaemonRange() {
        let many = (0..<12).map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.1, root: .leaf(PaneID("p\($0)"))) }
        let plan = NewColumnWidth.plan(mode: .fitScreen, columns: many, anchor: "c0", visible: many.map(\.id), fixedWidth: 0.5)
        #expect(plan.width == 0.1)
        #expect(plan.resizes.isEmpty)
    }
}

/// `layout.splitSizing` = even: every pane along the split axis in that
/// chain gets an equal share; the split pane counts as two.
@Suite struct EvenSplitRatiosTests {
    @Test func aLonePaneNeedsNoChange() {
        #expect(EvenSplitRatios.changes(splitting: "a", axis: .vertical, in: .leaf("a")).isEmpty)
    }

    @Test func splittingTheSecondOfTwoGivesThirds() {
        let root = SplitNode.split("x", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
        let changes = EvenSplitRatios.changes(splitting: "b", axis: .vertical, in: root)
        #expect(changes.count == 1)
        #expect(changes.first?.split == "x")
        #expect(abs((changes.first?.ratio ?? 0) - 1.0 / 3.0) < 1e-9)
    }

    @Test func aResizedChainIsEqualizedEverywhere() {
        // a over (b over c), user-resized; splitting a gives four equal rows.
        let root = SplitNode.split("x", axis: .vertical, ratio: 0.8, a: .leaf("a"),
                                   b: .split("y", axis: .vertical, ratio: 0.2, a: .leaf("b"), b: .leaf("c")))
        let changes = Dictionary(uniqueKeysWithValues: EvenSplitRatios.changes(splitting: "a", axis: .vertical, in: root).map { ($0.split, $0.ratio) })
        #expect(abs((changes["x"] ?? 0) - 0.5) < 1e-9)
        #expect(abs((changes["y"] ?? 0) - 0.5) < 1e-9)
    }

    @Test func aPerpendicularSubtreeCountsAsOneCellAndStaysAsItIs() {
        // a over (b | c): splitting a vertically equalizes the rows only.
        let root = SplitNode.split("x", axis: .vertical, ratio: 0.5, a: .leaf("a"),
                                   b: .split("y", axis: .horizontal, ratio: 0.3, a: .leaf("b"), b: .leaf("c")))
        let changes = EvenSplitRatios.changes(splitting: "a", axis: .vertical, in: root)
        #expect(changes.map(\.split) == ["x"])
        #expect(abs((changes.first?.ratio ?? 0) - 2.0 / 3.0) < 1e-9)
    }

    @Test func aSplitAcrossTheParentAxisChangesNothingAbove() {
        let root = SplitNode.split("x", axis: .vertical, ratio: 0.7, a: .leaf("a"), b: .leaf("b"))
        #expect(EvenSplitRatios.changes(splitting: "b", axis: .horizontal, in: root).isEmpty)
    }

    @Test func onlyTheChainHoldingThePaneChanges() {
        // (a | b) over c, split a horizontally: the inner chain becomes
        // thirds; the vertical split above keeps its ratio.
        let root = SplitNode.split("x", axis: .vertical, ratio: 0.6,
                                   a: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")), b: .leaf("c"))
        let changes = EvenSplitRatios.changes(splitting: "a", axis: .horizontal, in: root)
        #expect(changes.map(\.split) == ["y"])
        #expect(abs((changes.first?.ratio ?? 0) - 2.0 / 3.0) < 1e-9)
    }
}

@Suite @MainActor struct LayoutModelSplitSizingTests {
    private func model(_ sizing: SplitSizing) -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "c", root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))),
            LayoutColumn(id: "d", root: .leaf("e")),
        ]))])
        model.splitSizingOverride = sizing
        return model
    }

    @Test func evenEqualizesTheColumnsChainAfterTheSplit() {
        let model = model(.even)
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        let changes = model.splitSizingChanges(splitting: "b", axis: .vertical)
        #expect(changes.map(\.split) == ["x"])
        model.applySplitSizing(changes)
        guard case let .setSplitRatio(split, ratio, _, .ended)? = intents.first else {
            Issue.record("expected a ratio intent, got \(intents)")
            return
        }
        #expect(split == "x" && abs(ratio - 1.0 / 3.0) < 1e-9)
    }

    @Test func halveLeavesOtherPanesAlone() {
        #expect(model(.halve).splitSizingChanges(splitting: "b", axis: .vertical).isEmpty)
    }

    @Test func theDefaultIsEven() {
        let model = LayoutModel()
        model.followsDesignMetrics = false
        #expect(model.splitSizing == .even)
        #expect(model.newColumnWidthMode == .matchCurrent)
    }
}
