import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// `PaneMotionPlan` (plans/cmux-next/chrome-parity/p03-rendering.md R2, task 021): one structural
/// change as rest values only. Every fixture builds both geometries with `ScreenGeometry.compute`, as
/// `ScreenContentView.reconcile` does, and checks the plan against them: what changed is listed with
/// its rest rects and token, what did not is absent.
@MainActor
struct PaneMotionPlanTests {
    static let viewport = CGSize(width: 1200, height: 800)

    static func geometry(_ layout: ScreenLayout) -> ScreenGeometry {
        ScreenGeometry.compute(layout, viewport: viewport, style: LayoutStyle(), scale: 2)
    }

    static func splits(_ tree: SplitNode) -> ScreenGeometry { geometry(.splits(tree)) }

    static func side(_ a: SplitNode, _ b: SplitNode, id: SplitID = "s") -> SplitNode {
        .split(id, axis: .horizontal, ratio: 0.5, a: a, b: b)
    }

    static func stacked(_ a: SplitNode, _ b: SplitNode, id: SplitID = "v") -> SplitNode {
        .split(id, axis: .vertical, ratio: 0.5, a: a, b: b)
    }

    /// p1 p2 / p3 p4.
    static let grid2 = stacked(side(.leaf("p1"), .leaf("p2"), id: "t"), side(.leaf("p3"), .leaf("p4"), id: "b"))

    /// A strip column of three stacked panes `c<i>p0`...`c<i>p2`.
    static func column(_ index: Int, width: Double = 0.5) -> LayoutColumn {
        let pane = { (row: Int) -> SplitNode in .leaf(PaneID("c\(index)p\(row)")) }
        let root: SplitNode = .split(SplitID("c\(index)a"), axis: .vertical, ratio: 1.0 / 3, a: pane(0),
                                     b: .split(SplitID("c\(index)b"), axis: .vertical, ratio: 0.5, a: pane(1), b: pane(2)))
        return LayoutColumn(id: ColumnID("c\(index)"), width: width, root: root)
    }

    /// Ten columns of three panes: 30 panes, the strip five viewports wide.
    static let thirty = (0..<10).map { column($0) }

    static func leafColumn(_ id: String, width: Double = 0.5) -> LayoutColumn {
        LayoutColumn(id: ColumnID(id), width: width, root: .leaf(PaneID("p-\(id)")))
    }

    // MARK: Split

    @Test func splitRightGrowsTheNewPaneFromTheOldEdge() throws {
        let before = Self.splits(.leaf("p1")), after = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        let old = try #require(before.panes["p1"]), kept = try #require(after.panes["p1"]), target = try #require(after.panes["p2"])

        let added = try #require(plan.panes["p2"])
        #expect(added.presence == .appears)
        #expect(added.to == target)
        // A sliver on the line where p1's right edge was, the divider's gap kept beside it.
        #expect(added.from == CGRect(x: old.maxX + (target.minX - kept.maxX), y: target.minY, width: 0, height: target.height))
        #expect(added.token == PaneMotionVariant.standard.splitSpring)
        #expect(added.zoomRank == .normal)

        let split = try #require(plan.panes["p1"])
        #expect(split.presence == .stays)
        #expect(split.from == old)
        #expect(split.to == kept)
        #expect(split.token == .split)

        // The new divider slides from the old edge with the panes on either side of it.
        let divider = try #require(plan.dividers[.split("s")])
        let handle = try #require(after.dividers.first { $0.id == "s" })
        #expect(divider.presence == .appears)
        #expect(divider.to == handle.hitFrame)
        #expect(divider.from == handle.hitFrame.offsetBy(dx: old.maxX - kept.maxX, dy: 0))
        #expect(plan.camera.isEmpty)
        #expect(plan.covered.isEmpty && plan.uncovered.isEmpty)
    }

    @Test func splitDownGrowsTheNewPaneFromTheOldBottomEdge() throws {
        let before = Self.splits(.leaf("p1")), after = Self.splits(Self.stacked(.leaf("p1"), .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        let old = try #require(before.panes["p1"]), kept = try #require(after.panes["p1"]), target = try #require(after.panes["p2"])
        let added = try #require(plan.panes["p2"])
        #expect(added.from == CGRect(x: target.minX, y: old.maxY + (target.minY - kept.maxY), width: target.width, height: 0))
        #expect(added.to == target)
        let handle = try #require(after.dividers.first { $0.id == "v" })
        #expect(plan.dividers[.split("v")]?.from == handle.hitFrame.offsetBy(dx: 0, dy: old.maxY - kept.maxY))
    }

    @Test func aPaneTheChangeDoesNotMoveIsAbsent() throws {
        let before = Self.splits(Self.stacked(.leaf("p1"), .leaf("p3"), id: "a"))
        let after = Self.splits(Self.stacked(Self.side(.leaf("p1"), .leaf("p2")), .leaf("p3"), id: "a"))
        #expect(before.panes["p3"] == after.panes["p3"])
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        #expect(Set(plan.panes.keys) == ["p1", "p2"])
        // The divider above p3 kept its place; only the new one is listed.
        #expect(Set(plan.dividers.keys) == [.split("s")])
    }

    // MARK: Close

    @Test func closeLetsTheGoneLeaveAtItsRestAndGrowsItsNeighbour() throws {
        let before = Self.splits(Self.stacked(Self.side(.leaf("p1"), .leaf("p2")), .leaf("p3"), id: "a"))
        let after = Self.splits(Self.stacked(.leaf("p1"), .leaf("p3"), id: "a"))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .close)
        #expect(Set(plan.panes.keys) == ["p1", "p2"])

        let gone = try #require(plan.panes["p2"])
        #expect(gone.presence == .disappears)
        #expect(gone.from == before.panes["p2"])
        #expect(gone.to == before.panes["p2"])
        #expect(gone.chrome == nil)

        let grows = try #require(plan.panes["p1"])
        #expect(grows.presence == .stays)
        #expect(grows.from == before.panes["p1"])
        #expect(grows.to == after.panes["p1"])
        #expect(grows.token == PaneMotionVariant.standard.closeSpring)

        #expect(plan.dividers[.split("s")]?.presence == .disappears)
        #expect(plan.dividers[.split("a")] == nil)
        #expect(plan.camera.token == PaneMotionVariant.standard.closeSpring)
    }

    @Test func theVariantPicksTheCloseAndSplitSprings() {
        let one = Self.splits(.leaf("p1")), two = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        for variant in PaneMotionVariant.allCases {
            let split = PaneMotionPlan.build(from: one, to: two, variant: variant)
            let close = PaneMotionPlan.build(from: two, to: one, variant: variant)
            #expect(split.panes.values.allSatisfy { $0.token == variant.splitSpring })
            #expect(close.panes.values.allSatisfy { $0.token == variant.closeSpring })
            #expect(close.dividers.values.allSatisfy { $0.token == variant.closeSpring })
        }
    }

    // MARK: Zoom

    @Test func zoomInPutsThePaneInFrontAndCoversTheRest() throws {
        let before = Self.splits(Self.grid2), after = Self.splits(.leaf("p1"))
        let plan = PaneMotionPlan.build(from: before, to: after, zoom: .zoomIn("p1"))
        #expect(plan.kind == .zoomIn)
        #expect(Set(plan.panes.keys) == ["p1"])
        let zooming = try #require(plan.panes["p1"])
        #expect(zooming.zoomRank == .front)
        #expect(zooming.token == PaneMotionVariant.standard.expandSpring)
        #expect(zooming.from == before.panes["p1"])
        #expect(zooming.to == after.panes["p1"])
        #expect(plan.covered == ["p2", "p3", "p4"])
        #expect(plan.uncovered.isEmpty)
        #expect(Set(plan.dividers.keys) == [.split("v"), .split("t"), .split("b")])
        #expect(plan.dividers.values.allSatisfy { $0.presence == .disappears })
    }

    @Test func zoomOutSpringsThePaneBackOverTheUncoveredOnes() throws {
        let before = Self.splits(.leaf("p1")), after = Self.splits(Self.grid2)
        let plan = PaneMotionPlan.build(from: before, to: after, zoom: .zoomOut("p1"))
        #expect(plan.kind == .zoomOut)
        #expect(Set(plan.panes.keys) == ["p1"])
        let zooming = try #require(plan.panes["p1"])
        #expect(zooming.zoomRank == .front)
        #expect(zooming.from == before.panes["p1"])
        #expect(zooming.to == after.panes["p1"])
        #expect(plan.uncovered == ["p2", "p3", "p4"])
        // The dividers come back in place under the zoomed pane.
        #expect(plan.dividers.values.allSatisfy { $0.presence == .appears && $0.from == $0.to })
    }

    @Test func zoomOfAStripPaneStartsWhereItShowed() throws {
        let columns = [Self.leafColumn("c0"), Self.leafColumn("c1"), Self.leafColumn("c2")]
        let strip = Self.geometry(.columns(columns)), zoomed = Self.splits(.leaf("p-c2"))
        let offset = strip.maxOffset
        let plan = PaneMotionPlan.build(from: strip, camera: .init(stripOffset: offset), to: zoomed, zoom: .zoomIn("p-c2"))
        let zooming = try #require(plan.panes["p-c2"])
        let rested = try #require(strip.panes["p-c2"])
        // Out of the strip: `from` is where it showed under the strip camera, in the view's space.
        #expect(!zooming.inStrip)
        #expect(zooming.from == rested.offsetBy(dx: strip.viewShift(offset: offset), dy: 0))
        // The strip camera is set where it rests, not sprung.
        #expect(plan.camera.stripOffset?.isStill == true)
    }

    // MARK: Columns

    @Test func newColumnAtThirtyPanesListsOnlyTheNewColumn() throws {
        let before = Self.geometry(.columns(Self.thirty))
        let after = Self.geometry(.columns(Self.thirty + [Self.leafColumn("new")]))
        #expect(before.panes.count == 30)
        let plan = PaneMotionPlan.build(from: before, camera: .init(stripOffset: before.maxOffset),
                                        to: after, camera: .init(stripOffset: after.maxOffset))
        // No pane gave up its room: the column lands in place and the camera brings it in.
        #expect(plan.kind == .move)
        #expect(Set(plan.panes.keys) == ["p-new"])
        let added = try #require(plan.panes["p-new"])
        #expect(added.presence == .appears)
        #expect(added.inStrip)
        #expect(added.from == added.to)
        #expect(added.to == after.panes["p-new"])
        #expect(Set(plan.dividers.keys) == [.columnEdge("new")])
        #expect(plan.camera.stripOffset == PaneMotionPlan.Travel<CGFloat>(from: before.maxOffset, to: after.maxOffset))
        #expect(plan.camera.token == .scroll)
        #expect(plan.camera.stripOrigin == nil)
    }

    @Test func columnInsertedMidStripSlidesTheColumnsAfterItWithoutResizing() throws {
        let columns = [Self.leafColumn("c0"), Self.leafColumn("c1"), Self.leafColumn("c2")]
        let before = Self.geometry(.columns(columns))
        let after = Self.geometry(.columns([columns[0], Self.leafColumn("mid"), columns[1], columns[2]]))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(Set(plan.panes.keys) == ["p-mid", "p-c1", "p-c2"])
        for pane: PaneID in ["p-c1", "p-c2"] {
            let slides = try #require(plan.panes[pane])
            #expect(slides.presence == .stays)
            #expect(slides.from.size == slides.to.size)
            #expect(slides.from.minX < slides.to.minX)
            // Same size: the chrome sublayers ride the host, no spring of their own.
            #expect(slides.chrome == nil)
        }
        #expect(plan.dividers[.columnEdge("c0")] == nil)
        #expect(plan.dividers[.columnEdge("mid")]?.presence == .appears)
        #expect(plan.dividers[.columnEdge("c1")]?.presence == .stays)
        #expect(plan.dividers[.columnEdge("c2")]?.presence == .stays)
    }

    @Test func closingTheLastColumnPullsTheCameraBackOnTheCloseSpring() throws {
        let columns = (0..<4).map { Self.leafColumn("c\($0)") }
        let before = Self.geometry(.columns(columns)), after = Self.geometry(.columns(Array(columns.dropLast())))
        #expect(before.maxOffset > after.maxOffset)
        let plan = PaneMotionPlan.build(from: before, camera: .init(stripOffset: before.maxOffset),
                                        to: after, camera: .init(stripOffset: after.maxOffset))
        #expect(plan.kind == .close)
        #expect(Set(plan.panes.keys) == ["p-c3"])
        #expect(plan.panes["p-c3"]?.presence == .disappears)
        #expect(Set(plan.dividers.keys) == [.columnEdge("c3")])
        #expect(plan.camera.stripOffset == PaneMotionPlan.Travel<CGFloat>(from: before.maxOffset, to: after.maxOffset))
        #expect(plan.camera.token == PaneMotionVariant.standard.closeSpring)
    }

    @Test func aCameraOnlyChangeMovesNoPane() {
        let strip = Self.geometry(.columns(Self.thirty))
        let plan = PaneMotionPlan.build(from: strip, camera: .init(stripOffset: 0), to: strip, camera: .init(stripOffset: 300))
        #expect(plan.panes.isEmpty)
        #expect(plan.dividers.isEmpty)
        #expect(plan.camera.stripOffset == PaneMotionPlan.Travel<CGFloat>(from: 0, to: 300))
        #expect(plan.camera.token == .scroll)
        #expect(PaneMotionPlan.build(from: strip, to: strip).isEmpty)
    }

    // MARK: Retarget

    /// A change that lands mid-spring is a new plan from the last rest to the next one: nothing in it
    /// depends on the plan before or on what shows (the additive springs already running carry the
    /// velocity), so the same two rests always give the same plan.
    @Test func aRetargetPlansFromTheLastRest() throws {
        let one = Self.splits(.leaf("p1"))
        let two = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let three = Self.splits(Self.side(.leaf("p1"), Self.side(.leaf("p2"), .leaf("p3"), id: "t")))
        _ = PaneMotionPlan.build(from: one, to: two)

        let next = PaneMotionPlan.build(from: two, to: three)
        #expect(next == PaneMotionPlan.build(from: two, to: three))
        #expect(next.kind == .split)
        // p1 rests where the first change left it.
        #expect(next.panes["p1"] == nil)
        #expect(next.panes["p2"]?.from == two.panes["p2"])
        #expect(next.panes["p2"]?.to == three.panes["p2"])
        #expect(next.panes["p3"]?.presence == .appears)

        // The split taken back before it lands: a close from its rest.
        let back = PaneMotionPlan.build(from: two, to: one)
        #expect(back.kind == .close)
        #expect(back.panes["p1"]?.from == two.panes["p1"])
        #expect(back.panes["p1"]?.to == one.panes["p1"])
        #expect(back.panes["p2"]?.presence == .disappears)
    }

    // MARK: Chrome sublayers

    @Test func aResizedPaneCarriesItsChromeSublayerRestFrames() throws {
        let before = Self.splits(.leaf("p1")), after = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let shape = PaneMotionPlan.ChromeShape(padding: 6, cornerRadius: 10, ringCornerRadius: 12)
        let plan = PaneMotionPlan.build(from: before, to: after, shape: shape,
                                        bands: ["p1": PaneMotionPlan.ChromeBands(header: 28, footer: 0)])
        let chrome = try #require(plan.panes["p1"]?.chrome)
        let fromSize = try #require(before.panes["p1"]).size, toSize = try #require(after.panes["p1"]).size
        for (frames, size) in [(chrome.from, fromSize), (chrome.to, toSize)] {
            let padded = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            #expect(frames.padded == padded)
            #expect(frames.header == CGRect(x: padded.minX, y: padded.minY, width: padded.width, height: 28))
            #expect(frames.footer.height == 0)
            #expect(frames.rounded == CGRect(x: padded.minX, y: padded.minY + 28, width: padded.width, height: padded.height - 28))
            #expect(frames.cornerRadius == 10)
            #expect(frames.ringCornerRadius == 12)
            #expect(!frames.dimRoundsTop)
            #expect(frames.dimRoundsBottom)
        }
        // The same frames `PaneOverlayView.layoutLayers` gives its sublayers at that size.
        var style = LayoutStyle()
        style.panePadding = 6
        style.paneCornerRadius = 10
        let padded = PaneChromeGeometry.contentRect(forCell: CGRect(origin: .zero, size: toSize), style: style)
        #expect(chrome.to.rounded == PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 28))
        // The new pane has no bands: the whole padded rect is its content area.
        let added = try #require(plan.panes["p2"]?.chrome)
        #expect(added.to.rounded == added.to.padded)
        #expect(added.to.dimRoundsTop && added.to.dimRoundsBottom)
    }

    @Test func theRingRadiusIsClampedToTheContentArea() {
        let frames = PaneMotionPlan.ChromeFrames(cellSize: CGSize(width: 20, height: 400),
                                                 shape: .init(padding: 0, cornerRadius: 30, ringCornerRadius: 40),
                                                 bands: .init())
        #expect(frames.cornerRadius == 10)
        #expect(frames.ringCornerRadius == 10)
    }

    // MARK: Budget

    #if DEBUG
    /// Debug has no optimizer: ten times the Release budget, which still catches a walk per pane.
    static let buildBudget = Duration.milliseconds(2)
    #else
    static let buildBudget = Duration.microseconds(200)
    #endif

    /// A split inside a 30-pane strip, the heaviest common plan (`PaneArrival.split` walks every
    /// pane): p95 of 300 builds under 0.2 ms in Release.
    @Test func thirtyPaneBuildFitsTheBudget() {
        var columns = Self.thirty
        columns[4].root = .split("x", axis: .horizontal, ratio: 0.5, a: columns[4].root, b: .leaf("p-split"))
        let before = Self.geometry(.columns(Self.thirty)), after = Self.geometry(.columns(columns))
        let camera = PaneMotionPlan.Camera(stripOffset: 600)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(300)
        var listed = 0
        for _ in 0..<300 {
            let start = clock.now
            let plan = PaneMotionPlan.build(from: before, camera: camera, to: after, camera: camera)
            samples.append(clock.now - start)
            listed += plan.panes.count
        }
        #expect(listed > 0)
        samples.sort()
        let p95 = samples[samples.count * 95 / 100]
        #expect(p95 < Self.buildBudget, "30-pane plan p95 \(p95), budget \(Self.buildBudget)")
    }
}
