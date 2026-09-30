import CoreGraphics
import Testing
import CmuxNextDesign
@testable import CmuxNextLayout

private func style(gap: CGFloat = 8) -> LayoutStyle {
    var style = LayoutStyle()
    style.columnGap = gap
    style.dividerThickness = 1
    style.dividerHitThickness = 9
    style.paneChromeHeight = 0
    style.minimumPaneContentSize = CGSize(width: 20, height: 20)
    return style
}

@Suite struct SplitGeometryTests {
    @Test func singleLeafFillsRect() {
        let result = SplitGeometry.layout(.leaf("a"), in: CGRect(x: 0, y: 0, width: 800, height: 600), style: style())
        #expect(result.panes["a"] == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(result.dividers.isEmpty)
    }

    @Test func horizontalSplitDividesWidthMinusDivider() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 801, height: 600), style: style())
        #expect(result.panes["a"] == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(result.panes["b"] == CGRect(x: 401, y: 0, width: 400, height: 600))
        let divider = try! #require(result.dividers.first)
        #expect(divider.id == "s")
        #expect(divider.frame == CGRect(x: 400, y: 0, width: 1, height: 600))
        #expect(divider.hitFrame == CGRect(x: 396, y: 0, width: 9, height: 600))
    }

    @Test func nestedVerticalSplitUsesTopLeftOrigin() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.25,
                                   a: .leaf("a"),
                                   b: .split("t", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 401, height: 201), style: style())
        #expect(result.panes["a"] == CGRect(x: 0, y: 0, width: 100, height: 201))
        #expect(result.panes["b"] == CGRect(x: 101, y: 0, width: 300, height: 100))
        #expect(result.panes["c"] == CGRect(x: 101, y: 101, width: 300, height: 100))
        #expect(result.dividers.map(\.id) == ["s", "t"])
    }

    @Test func extentsRoundToDevicePixels() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 1.0 / 3.0, a: .leaf("a"), b: .leaf("b"))
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 100, height: 10), style: style(), scale: 2)
        let a = result.panes["a"]!.width
        #expect((a * 2).rounded() == a * 2)
    }

    @Test func minimumExtentClampsTinyRatios() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.01, a: .leaf("a"), b: .leaf("b"))
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 400, height: 100), style: style())
        #expect(result.panes["a"]!.width == 20)
    }

    @Test func pointerToRatioRoundTripsWithGrabOffset() {
        let container = CGRect(x: 100, y: 0, width: 401, height: 300)
        let ratio = SplitGeometry.ratio(forPointer: 303, grabOffset: 3, container: container, axis: .horizontal, style: style())
        #expect(abs(ratio - 0.5) < 1e-9)
    }

    @Test func pointerRatioClampsToDaemonRange() {
        let container = CGRect(x: 0, y: 0, width: 10_000, height: 300)
        let low = SplitGeometry.ratio(forPointer: -500, container: container, axis: .horizontal, style: style())
        let high = SplitGeometry.ratio(forPointer: 20_000, container: container, axis: .horizontal, style: style())
        #expect(low == 0.05)
        #expect(high == 0.95)
    }

    @Test func equalizeCountsSameAxisCells() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.8,
                                   a: .leaf("a"),
                                   b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        #expect(abs(tree.equalizedRatio(for: "s")! - 1.0 / 3.0) < 1e-9)
        let perpendicular = SplitNode.split("s", axis: .horizontal, ratio: 0.8,
                                            a: .leaf("a"),
                                            b: .split("t", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        #expect(perpendicular.equalizedRatio(for: "s") == 0.5)
    }
}

@Suite struct ColumnGeometryTests {
    @Test func twoHalfColumnsFillViewportExactly() {
        let strip = ColumnStripGeometry.frames(widths: [0.5, 0.5], viewport: CGSize(width: 1000, height: 500), gap: 8)
        #expect(strip.frames[0] == CGRect(x: 8, y: 0, width: 488, height: 500))
        #expect(strip.frames[1] == CGRect(x: 504, y: 0, width: 488, height: 500))
        #expect(strip.contentWidth == 1000)
    }

    @Test func widthFractionRoundTrips() {
        for preset in ColumnWidthPreset.allCases {
            let px = ColumnStripGeometry.pixelWidth(fraction: preset.rawValue, viewportWidth: 1200, gap: 8)
            let back = ColumnStripGeometry.fraction(forPixelWidth: px, viewportWidth: 1200, gap: 8)
            #expect(abs(back - preset.rawValue) < 1e-9)
        }
        #expect(ColumnStripGeometry.fraction(forPixelWidth: 1, viewportWidth: 1200, gap: 8) == 0.1)
        #expect(ColumnStripGeometry.fraction(forPixelWidth: 5000, viewportWidth: 1200, gap: 8) == 1.0)
    }

    @Test func snapOffsetsIncludeLeadingAndTrailingEdges() {
        // Viewport 1000, gap 0: columns 600, 500, 400 -> content 1500, max offset 500.
        let strip = ColumnStripGeometry.frames(widths: [0.6, 0.5, 0.4], viewport: CGSize(width: 1000, height: 100), gap: 0)
        let snaps = ColumnStripGeometry.snapOffsets(frames: strip.frames, contentWidth: strip.contentWidth, viewportWidth: 1000, gap: 0)
        #expect(strip.contentWidth == 1500)
        #expect(snaps == [0, 100, 500])
    }

    @Test func snapTargetUsesProjectedPosition() {
        let snaps: [CGFloat] = [0, 400, 800, 1200]
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 150, velocity: 0, snaps: snaps) == 0)
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 250, velocity: 0, snaps: snaps) == 400)
        // 1500 pt/s projects about 748 pt further.
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 100, velocity: 1500, snaps: snaps) == 800)
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 1100, velocity: -1500, snaps: snaps) == 400)
    }

    @Test func slowFlingStillAdvancesOneSnap() {
        let snaps: [CGFloat] = [0, 400, 800]
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 20, velocity: 320, snaps: snaps) == 400)
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 780, velocity: -320, snaps: snaps) == 400)
        #expect(ColumnStripGeometry.snapTarget(releaseOffset: 20, velocity: 100, snaps: snaps) == 0)
    }

    @Test func adjacentSnapSteps() {
        let snaps: [CGFloat] = [0, 400, 800]
        #expect(ColumnStripGeometry.adjacentSnap(from: 0, direction: 1, snaps: snaps) == 400)
        #expect(ColumnStripGeometry.adjacentSnap(from: 400, direction: -1, snaps: snaps) == 0)
        #expect(ColumnStripGeometry.adjacentSnap(from: 800, direction: 1, snaps: snaps) == 800)
    }

    @Test func minimalRevealScrollsLeastAmount() {
        let frame = CGRect(x: 1208, y: 0, width: 400, height: 100)
        let offset = ColumnStripGeometry.revealOffset(for: frame, current: 0, viewportWidth: 1000, contentWidth: 3000, gap: 8, mode: .minimal)
        #expect(offset == CGFloat(616))
        let visible = ColumnStripGeometry.revealOffset(for: CGRect(x: 108, y: 0, width: 300, height: 100), current: 0, viewportWidth: 1000, contentWidth: 3000, gap: 8, mode: .minimal)
        #expect(visible == 0)
        let behind = ColumnStripGeometry.revealOffset(for: CGRect(x: 208, y: 0, width: 300, height: 100), current: 500, viewportWidth: 1000, contentWidth: 3000, gap: 8, mode: .minimal)
        #expect(behind == 200)
    }

    @Test func centerRevealClampsAtEnds() {
        let frame = CGRect(x: 1000, y: 0, width: 400, height: 100)
        #expect(ColumnStripGeometry.revealOffset(for: frame, current: 0, viewportWidth: 1000, contentWidth: 3000, gap: 8, mode: .center) == 700)
        let first = CGRect(x: 8, y: 0, width: 400, height: 100)
        #expect(ColumnStripGeometry.revealOffset(for: first, current: 900, viewportWidth: 1000, contentWidth: 3000, gap: 8, mode: .center) == 0)
    }

    @Test func rubberBandResistsPastEnds() {
        let banded = ColumnStripGeometry.rubberBand(-200, contentWidth: 2000, viewportWidth: 1000)
        #expect(banded < 0 && banded > -200)
        #expect(ColumnStripGeometry.rubberBand(500, contentWidth: 2000, viewportWidth: 1000) == 500)
        let over = ColumnStripGeometry.rubberBand(1300, contentWidth: 2000, viewportWidth: 1000)
        #expect(over > 1000 && over < 1300)
    }

    @Test func presetCyclingWraps() {
        #expect(ColumnWidthPreset.next(after: 2.0 / 3.0) == .full)
        #expect(ColumnWidthPreset.next(after: 1.0) == .oneThird)
        #expect(ColumnWidthPreset.next(after: 0.4) == .half)
        #expect(ColumnWidthPreset.next(after: 0.5, forward: false) == .oneThird)
        #expect(ColumnWidthPreset.next(after: 1.0 / 3.0, forward: false) == .full)
    }

    @Test func screenGeometryPlacesColumnTreesAndEdges() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.5, root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("c")),
        ])
        let geometry = ScreenGeometry.compute(layout, viewport: CGSize(width: 1000, height: 401), style: style())
        #expect(geometry.panes["a"] == CGRect(x: 8, y: 0, width: 488, height: 200))
        #expect(geometry.panes["b"] == CGRect(x: 8, y: 201, width: 488, height: 200))
        #expect(geometry.panes["c"] == CGRect(x: 504, y: 0, width: 488, height: 401))
        #expect(geometry.columnEdges.map(\.column) == ["c1", "c2"])
        #expect(geometry.gapZones.map(\.after) == [nil, "c1", "c2"])
        #expect(geometry.maxOffset == 0)
    }
}

@Suite struct DropZoneTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func edgesAndCenter() {
        let s = style()
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 10, y: 150), in: rect, style: s) == .left)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 390, y: 150), in: rect, style: s) == .right)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 200, y: 10), in: rect, style: s) == .top)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 200, y: 290), in: rect, style: s) == .bottom)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 200, y: 150), in: rect, style: s) == .center)
    }

    @Test func cornerPicksRelativelyNearerEdge() {
        // Band x = 112, band y = 84. (20, 30): left 0.18 vs top 0.36.
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 20, y: 30), in: rect, style: style()) == .left)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 60, y: 5), in: rect, style: style()) == .top)
    }

    @Test func gapZoneWinsBetweenColumns() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
        ])
        let geometry = ScreenGeometry.compute(layout, viewport: CGSize(width: 1000, height: 400), style: style())
        #expect(DropZoneGeometry.target(at: CGPoint(x: 500, y: 200), screen: "s", geometry: geometry, style: style()) == .newColumn(screen: "s", after: "c1"))
        #expect(DropZoneGeometry.target(at: CGPoint(x: 2, y: 200), screen: "s", geometry: geometry, style: style()) == .newColumn(screen: "s", after: nil))
        #expect(DropZoneGeometry.target(at: CGPoint(x: 250, y: 200), screen: "s", geometry: geometry, style: style()) == .pane("a", .center))
        #expect(DropZoneGeometry.target(at: CGPoint(x: 700, y: 390), screen: "s", geometry: geometry, style: style()) == .pane("b", .bottom))
    }

    @Test func highlightRectsCoverHalves() {
        let geometry = ScreenGeometry.compute(.splits(.leaf("a")), viewport: CGSize(width: 400, height: 300), style: style())
        #expect(DropZoneGeometry.highlightRect(for: .pane("a", .left), geometry: geometry, style: style()) == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(DropZoneGeometry.highlightRect(for: .pane("a", .bottom), geometry: geometry, style: style()) == CGRect(x: 0, y: 150, width: 400, height: 150))
        #expect(DropZoneGeometry.highlightRect(for: .pane("a", .center), geometry: geometry, style: style()) == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}

@Suite struct FocusNavigationTests {
    private let frames: [PaneID: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 100, height: 200),
        "b": CGRect(x: 101, y: 0, width: 100, height: 120),
        "c": CGRect(x: 101, y: 121, width: 100, height: 79),
        "d": CGRect(x: 400, y: 0, width: 100, height: 200),
    ]

    @Test func movesToOverlappingNeighbor() {
        #expect(FocusNavigation.neighbor(of: "a", direction: .right, frames: frames) == "b")
        #expect(FocusNavigation.neighbor(of: "c", direction: .left, frames: frames) == "a")
        #expect(FocusNavigation.neighbor(of: "b", direction: .down, frames: frames) == "c")
        #expect(FocusNavigation.neighbor(of: "c", direction: .right, frames: frames) == "d")
        #expect(FocusNavigation.neighbor(of: "a", direction: .left, frames: frames) == nil)
    }
}

@Suite struct SpringTests {
    @Test func settlesOnTarget() {
        var value = SpringValue(0)
        value.target = 100
        var frames = 0
        while value.advance(1.0 / 120.0, parameters: MotionSpring.move.base, epsilon: 0.25) {
            frames += 1
            #expect(frames < 240)
        }
        #expect(value.value == 100)
        #expect(value.velocity == 0)
    }

    @Test func frameRateIndependent() {
        var fast = SpringValue(0)
        var slow = SpringValue(0)
        fast.target = 100
        slow.target = 100
        for _ in 0..<12 { fast.step(1.0 / 120.0, parameters: MotionSpring.move.base) }
        for _ in 0..<6 { slow.step(1.0 / 60.0, parameters: MotionSpring.move.base) }
        #expect(abs(fast.value - slow.value) < 0.01)
    }
}

@Suite struct LayoutModelTests {
    private func makeModel() -> (LayoutModel, Recorder) {
        let screen = LayoutScreen(id: "s", name: "", layout: .columns([
            LayoutColumn(id: "c1", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("c")),
        ]))
        let model = LayoutModel(screens: [screen])
        let recorder = Recorder()
        model.intentHandler = { recorder.intents.append($0) }
        return (model, recorder)
    }

    final class Recorder { var intents: [LayoutIntent] = [] }

    @Test func changedIntentsCoalescePerFrame() {
        let (model, recorder) = makeModel()
        let transaction = LayoutTransactionID("t")
        model.setSplitRatio("x", ratio: 0.3, transaction: transaction, phase: .changed)
        model.setSplitRatio("x", ratio: 0.4, transaction: transaction, phase: .changed)
        #expect(recorder.intents.isEmpty)
        #expect(model.screens[0].layout.ratio(of: "x") == 0.4)
        model.flushPendingGestureIntents()
        #expect(recorder.intents == [.setSplitRatio("x", ratio: 0.4, transaction: transaction, phase: .changed)])
        model.setSplitRatio("x", ratio: 0.45, transaction: transaction, phase: .ended)
        #expect(recorder.intents.last == .setSplitRatio("x", ratio: 0.45, transaction: transaction, phase: .ended))
        #expect(!model.hasPendingGestureIntents)
    }

    @Test func staleSnapshotDoesNotFightGesture() {
        let (model, _) = makeModel()
        let stale = model.screens
        model.setSplitRatio("x", ratio: 0.3, transaction: "t", phase: .changed)
        model.apply(screens: stale)
        #expect(model.screens[0].layout.ratio(of: "x") == 0.3)
        model.setSplitRatio("x", ratio: 0.35, transaction: "t", phase: .ended)
        model.apply(screens: stale)
        #expect(model.screens[0].layout.ratio(of: "x") == 0.35)
        // Daemon confirms, then later external changes win.
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: stale[0].layout.settingRatio(0.35, for: "x"))])
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: stale[0].layout.settingRatio(0.7, for: "x"))])
        #expect(model.screens[0].layout.ratio(of: "x") == 0.7)
    }

    @Test func unsettledGestureValueSurvivesStaleSnapshots() {
        let (model, _) = makeModel()
        let stale = model.screens
        model.setSplitRatio("x", ratio: 0.3, transaction: "t", phase: .ended)
        for _ in 0..<5 { model.apply(screens: stale) }
        #expect(model.screens[0].layout.ratio(of: "x") == 0.3)
    }

    @Test func rejectedTransactionRestoresDaemonValue() {
        let (model, _) = makeModel()
        let stale = model.screens
        model.setSplitRatio("x", ratio: 0.3, transaction: "t", phase: .ended)
        model.apply(screens: stale)
        model.rejectTransaction("t")
        #expect(model.screens[0].layout.ratio(of: "x") == 0.5)
    }

    @Test func settledTransactionYieldsToNextSnapshot() {
        let (model, _) = makeModel()
        let stale = model.screens
        model.setSplitRatio("x", ratio: 0.3, transaction: "t", phase: .ended)
        model.settleTransaction("t")
        #expect(model.screens[0].layout.ratio(of: "x") == 0.3)
        // The daemon clamped the value; the post-commit snapshot wins.
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: stale[0].layout.settingRatio(0.25, for: "x"))])
        #expect(model.screens[0].layout.ratio(of: "x") == 0.25)
    }

    @Test func settlingLiveGestureKeepsTracking() {
        let (model, _) = makeModel()
        let stale = model.screens
        model.setSplitRatio("x", ratio: 0.3, transaction: "t", phase: .changed)
        model.settleTransaction("t")
        model.apply(screens: stale)
        #expect(model.screens[0].layout.ratio(of: "x") == 0.3)
    }

    @Test func columnWidthIntentCarriesAPane() {
        let (model, recorder) = makeModel()
        model.focus("c")
        model.cycleColumnWidthPreset()
        #expect(recorder.intents.last == .setColumnWidth("c2", anyPane: "c", width: ColumnWidthPreset.twoThirds.rawValue, transaction: {
            if case let .setColumnWidth(_, _, _, t, _) = recorder.intents.last! { return t }
            return "none"
        }(), phase: .ended))
        #expect(model.screens[0].layout.columns[1].width == ColumnWidthPreset.twoThirds.rawValue)
    }

    @Test func focusFallsBackWhenPaneDisappears() {
        let (model, _) = makeModel()
        model.focus("c")
        model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))])
        #expect(model.focusedPane == "a")
    }

    @Test func equalizeEmitsEndedRatio() {
        let (model, recorder) = makeModel()
        model.setSplitRatio("x", ratio: 0.2, transaction: "t", phase: .ended)
        model.equalizeSplit("x")
        guard case let .setSplitRatio(id, ratio, _, phase) = recorder.intents.last else {
            Issue.record("no ratio intent")
            return
        }
        #expect(id == "x" && ratio == 0.5 && phase == .ended)
    }
}

@Suite struct MockSourceTests {
    @Test func dropOnGapCreatesColumn() {
        let source = MockLayoutSource()
        let before = source.model.screens[0].layout.columns.count
        source.model.dropTab("t", on: .newColumn(screen: "s1", after: "c1"))
        let columns = source.model.screens[0].layout.columns
        #expect(columns.count == before + 1)
        #expect(columns[1].root.panes == [source.model.focusedPane!])
    }

    @Test func dropOnLeftEdgeSplitsBeforePane() {
        let source = MockLayoutSource()
        source.model.dropTab("t", on: .pane("p3", .left))
        let column = source.model.screens[0].layout.columns[1]
        guard case let .split(_, axis, _, a, b) = column.root else {
            Issue.record("expected split")
            return
        }
        #expect(axis == .horizontal)
        #expect(b == .leaf("p3"))
        #expect(a.panes == [source.model.focusedPane!])
    }

    @Test func closingLastPaneOfColumnRemovesIt() {
        let source = MockLayoutSource()
        source.closePane("p3")
        #expect(source.model.screens[0].layout.columns.map(\.id) == ["c1", "c3"])
    }
}
