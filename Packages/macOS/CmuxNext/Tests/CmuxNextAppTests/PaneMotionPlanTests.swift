import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Foundation
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
        #expect(plan.camera.stripMinX == nil)
    }

    /// A column inserted mid-strip gives up no pane's room: the CPU path snaps it, so the plan sets
    /// the columns after it at their rest. Landing while panes still move, they slide.
    @Test func columnInsertedMidStripSetsTheColumnsAfterItAtRest() throws {
        let columns = [Self.leafColumn("c0"), Self.leafColumn("c1"), Self.leafColumn("c2")]
        let before = Self.geometry(.columns(columns))
        let after = Self.geometry(.columns([columns[0], Self.leafColumn("mid"), columns[1], columns[2]]))
        let snapped = PaneMotionPlan.build(from: before, to: after)
        #expect(snapped.kind == .move)
        #expect(Set(snapped.panes.keys) == ["p-mid", "p-c1", "p-c2"])
        #expect(snapped.panes.values.allSatisfy { $0.from == $0.to })
        #expect(snapped.dividers.values.allSatisfy { $0.from == $0.to })

        let carried = PaneMotionPlan.build(from: before, to: after, inFlight: true)
        #expect(Set(carried.panes.keys) == ["p-mid", "p-c1", "p-c2"])
        for pane: PaneID in ["p-c1", "p-c2"] {
            let slides = try #require(carried.panes[pane])
            #expect(slides.presence == .stays)
            #expect(slides.from == before.panes[pane])
            #expect(slides.from.size == slides.to.size)
            #expect(slides.from.minX < slides.to.minX)
            // Same size: the chrome sublayers ride the host, no spring of their own.
            #expect(slides.chrome == nil)
        }
        #expect(carried.dividers[.columnEdge("c0")] == nil)
        #expect(carried.dividers[.columnEdge("mid")]?.presence == .appears)
        #expect(carried.dividers[.columnEdge("c1")]?.presence == .stays)
        #expect(carried.dividers[.columnEdge("c2")]?.presence == .stays)
    }

    /// A ratio change keeps its structure: it springs, as a released divider or an equalize does.
    @Test func aRatioChangeSprings() throws {
        let before = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let after = Self.splits(.split("s", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after, structural: false)
        #expect(plan.kind == .move)
        #expect(plan.panes["p1"]?.from == before.panes["p1"])
        #expect(plan.panes["p1"]?.to == after.panes["p1"])
        #expect(plan.panes["p2"]?.from == before.panes["p2"])
        let handle = try #require(before.dividers.first { $0.id == "s" })
        #expect(plan.dividers[.split("s")]?.from == handle.hitFrame)
        #expect(plan.dividers[.split("s")]?.presence == .stays)
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

    // MARK: Docks

    /// Where a listed rect shows when the change starts: its container at the camera's `from`.
    static func shownAtStart(_ rect: CGRect, inStrip: Bool, _ plan: PaneMotionPlan, next: ScreenGeometry,
                             camera: PaneMotionPlan.Camera) -> CGRect {
        guard inStrip else { return rect }
        let minX = plan.camera.stripMinX?.from ?? next.stripMinX
        let offset = plan.camera.stripOffset?.from ?? camera.stripOffset
        return rect.offsetBy(dx: minX - offset, dy: 0)
    }

    /// Where a pane showed at rest in `geometry` under the strip offset `offset`.
    static func shown(_ pane: PaneID, in geometry: ScreenGeometry, offset: CGFloat) -> CGRect? {
        guard let rect = geometry.panes[pane] else { return nil }
        return geometry.isColumns && geometry.scrolls(pane: pane) ? rect.offsetBy(dx: geometry.viewShift(offset: offset), dy: 0) : rect
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    /// A top dock opening: the strip panes' own rects carry `stripMinY`, so the container moves only
    /// in x and each strip pane starts where it showed.
    @Test func aTopDockMovesTheStripPanesOnceVertically() throws {
        let columns = [Self.leafColumn("c0"), Self.leafColumn("c1")]
        let before = Self.geometry(.columns(columns))
        let top = LayoutColumn(id: "top", root: .leaf("p-top"), dock: DockColumn(edge: .top))
        let after = Self.geometry(.columns([top] + columns))
        #expect(after.stripMinY > before.stripMinY)
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        for pane: PaneID in ["p-c0", "p-c1"] {
            let change = try #require(plan.panes[pane])
            #expect(change.inStrip)
            let showed = try #require(Self.shown(pane, in: before, offset: 0)), shows = try #require(Self.shown(pane, in: after, offset: 0))
            // The pane's travel plus the camera's is what shows moving.
            let start = Self.shownAtStart(change.from, inStrip: true, plan, next: after, camera: .init())
            let rest = change.to.offsetBy(dx: plan.camera.stripMinX?.to ?? after.stripMinX, dy: 0)
            #expect(Self.same(start, showed))
            #expect(Self.same(rest, shows))
        }
    }

    /// An undock puts a fixed pane in the strip while the strip's origin moves back: its `from` is in
    /// the strip at the origin the camera starts from, so it starts where it showed.
    @Test func anUndockedPaneStartsWhereItShowed() throws {
        let leftDock = LayoutColumn(id: "c0", root: .leaf("p-c0"), dock: DockColumn(edge: .left))
        let rest = [Self.leafColumn("c1"), Self.leafColumn("c2")]
        let before = Self.geometry(.columns([leftDock] + rest)), after = Self.geometry(.columns([Self.leafColumn("c0")] + rest))
        #expect(before.stripMinX != after.stripMinX)
        // The CPU path carries an undock only in flight; settled, it is set at rest.
        let plan = PaneMotionPlan.build(from: before, to: after, inFlight: true)
        #expect(plan.camera.stripMinX == PaneMotionPlan.Travel<CGFloat>(from: before.stripMinX, to: after.stripMinX))
        let undocked = try #require(plan.panes["p-c0"])
        #expect(undocked.inStrip)
        let docked = try #require(before.panes["p-c0"])
        #expect(Self.same(Self.shownAtStart(undocked.from, inStrip: true, plan, next: after, camera: .init()), docked))
        for (pane, change) in plan.panes where change.presence == .stays {
            let showed = try #require(Self.shown(pane, in: before, offset: 0))
            #expect(Self.same(Self.shownAtStart(change.from, inStrip: change.inStrip, plan, next: after, camera: .init()), showed))
        }
    }

    // MARK: Split motion details

    /// With even split sizing the new divider lands past the new pane, on the far pane's edge: it
    /// starts where that edge starts, not on the split pane's.
    @Test func anEvenSplitsNewDividerRidesTheFarPanesEdge() throws {
        let before = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let after = Self.splits(.split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                       b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("new"), b: .leaf("p2"))))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        let old = try #require(before.panes["p2"]), kept = try #require(after.panes["p2"])
        let handle = try #require(after.dividers.first { $0.id == "t" })
        let divider = try #require(plan.dividers[.split("t")])
        #expect(divider.presence == .appears)
        #expect(divider.from == handle.hitFrame.offsetBy(dx: old.minX - kept.minX, dy: 0))
        #expect(plan.panes["p2"]?.from == old)
    }

    /// A content handoff: the added pane shows in place, the giver slides in from past the screen
    /// edge, and the new divider is in place.
    @Test func aHandoffLandsTheAddedPaneAndSlidesTheGiverIn() throws {
        let before = Self.splits(.leaf("p1")), after = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after, handoff: "p1")
        #expect(plan.kind == .split)
        let target = try #require(after.panes["p2"]), kept = try #require(after.panes["p1"])
        let added = try #require(plan.panes["p2"])
        #expect(added.presence == .appears)
        #expect(added.from == target)
        let giver = try #require(plan.panes["p1"])
        #expect(giver.presence == .stays)
        #expect(giver.from == kept.offsetBy(dx: after.clipMinX - kept.maxX, dy: 0))
        #expect(giver.to == kept)
        #expect(giver.token == PaneMotionVariant.standard.splitSpring)
        #expect(plan.dividers.values.allSatisfy { $0.presence == .appears && $0.from == $0.to })
    }

    // MARK: Retarget

    /// A change that lands mid-spring is a new plan from the last rest to the next one; the additive
    /// springs already running carry what shows.
    @Test func aRetargetPlansFromTheLastRest() throws {
        let one = Self.splits(.leaf("p1"))
        let two = Self.splits(Self.side(.leaf("p1"), .leaf("p2")))
        let three = Self.splits(Self.side(.leaf("p1"), Self.side(.leaf("p2"), .leaf("p3"), id: "t")))
        let first = PaneMotionPlan.build(from: one, to: two)

        // The daemon's echo of the split: the same geometry, so nothing to retarget.
        #expect(PaneMotionPlan.build(from: two, to: two).isEmpty)

        // A second split before the first lands: only what it moves, from the first's rest.
        let next = PaneMotionPlan.build(from: two, to: three)
        #expect(next.kind == .split)
        #expect(Set(next.panes.keys) == ["p2", "p3"])
        #expect(next.panes["p2"]?.from == first.panes["p2"]?.to)
        #expect(next.panes["p2"]?.to == three.panes["p2"])
        #expect(next.panes["p3"]?.presence == .appears)

        // The split taken back before it lands: a close from its rest, on the close spring.
        let back = PaneMotionPlan.build(from: two, to: one)
        #expect(back.kind == .close)
        #expect(back.panes["p1"]?.from == first.panes["p1"]?.to)
        #expect(back.panes["p1"]?.to == one.panes["p1"])
        #expect(back.panes["p2"]?.presence == .disappears)
        #expect(back.camera.token == PaneMotionVariant.standard.closeSpring)
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

    // MARK: Thirty panes

    /// A split inside a 30-pane strip, the heaviest common plan (`PaneArrival.split` walks every
    /// pane), lists only the split column. Its build time is `PaneMotionPlanBench`'s.
    @Test func aSplitInAThirtyPaneStripListsOnlyItsColumn() {
        let (before, after) = Self.thirtyPaneSplit()
        let camera = PaneMotionPlan.Camera(stripOffset: 600)
        let plan = PaneMotionPlan.build(from: before, camera: camera, to: after, camera: camera)
        #expect(plan.kind == .split)
        #expect(Set(plan.panes.keys) == ["c4p0", "c4p1", "c4p2", "p-split"])
        #expect(plan.camera.isEmpty)
    }

    static func thirtyPaneSplit() -> (before: ScreenGeometry, after: ScreenGeometry) {
        var columns = thirty
        columns[4].root = .split("x", axis: .horizontal, ratio: 0.5, a: columns[4].root, b: .leaf("p-split"))
        return (geometry(.columns(thirty)), geometry(.columns(columns)))
    }
}

/// The 30-pane plan build time (acceptance: p95 < 0.2 ms in Release). A measurement, not a gate:
/// run it optimized and quote the line.
///
/// ```
/// CMUX_PANE_MOTION_PLAN_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PaneMotionPlanBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_MOTION_PLAN_BENCH"] == "1"))
struct PaneMotionPlanBench {
    @Test func thirtyPaneBuild() {
        let (before, after) = PaneMotionPlanTests.thirtyPaneSplit()
        let camera = PaneMotionPlan.Camera(stripOffset: 600)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(1_000)
        var listed = 0
        for _ in 0..<1_000 {
            let start = clock.now
            let plan = PaneMotionPlan.build(from: before, camera: camera, to: after, camera: camera)
            samples.append(clock.now - start)
            listed += plan.panes.count
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100]
        let p99 = samples[samples.count * 99 / 100], worst = samples[samples.count - 1]
        print("pane-motion-plan bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), 30 panes, 1000 builds: "
              + "p50 \(p50), p95 \(p95), p99 \(p99), max \(worst) (listed \(listed))")
        #expect(listed > 0)
        #if !DEBUG
        #expect(p95 < .microseconds(200), "30-pane plan p95 \(p95), budget 0.2 ms")
        #endif
    }
}
