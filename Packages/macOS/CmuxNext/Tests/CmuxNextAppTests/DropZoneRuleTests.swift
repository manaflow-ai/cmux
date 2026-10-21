import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// The tab drop zone rule (plans/cmux-next/drop-zones/DESIGN.md): each edge owns a quarter of the
/// pane body (at least 48 pt, never more than a third), the edge the pointer is relatively nearest
/// wins a corner, and the middle joins the pane. The preview and the commit both read this rule.
struct DropZoneRuleTests {
    let style = LayoutStyle()

    func zone(_ x: CGFloat, _ y: CGFloat, in size: CGSize, previous: PaneDropZone? = nil) -> PaneDropZone {
        DropZoneGeometry.zone(at: CGPoint(x: x, y: y), in: CGRect(origin: .zero, size: size), style: style, previous: previous)
    }

    /// A big pane splits from its outer quarter, as classic cmux (Bonsplit) did: a 120 pt cap
    /// made the right quarter of a 1200 pt pane join it instead (user 2026-10-19).
    @Test(arguments: [
        (CGSize(width: 1200, height: 800), CGPoint(x: 250, y: 400), PaneDropZone.left),
        (CGSize(width: 1200, height: 800), CGPoint(x: 950, y: 400), .right),
        (CGSize(width: 1200, height: 800), CGPoint(x: 600, y: 180), .top),
        (CGSize(width: 1200, height: 800), CGPoint(x: 600, y: 620), .bottom),
        (CGSize(width: 2400, height: 1200), CGPoint(x: 2400 - 580, y: 600), .right),
    ])
    func outerQuarterSplits(size: CGSize, point: CGPoint, expected: PaneDropZone) {
        #expect(zone(point.x, point.y, in: size) == expected)
    }

    /// The middle half of each axis joins the pane on every pane size.
    @Test(arguments: [CGSize(width: 1200, height: 800), CGSize(width: 400, height: 300), CGSize(width: 2400, height: 1200)])
    func middleJoins(size: CGSize) {
        #expect(zone(size.width / 2, size.height / 2, in: size) == .center)
        #expect(zone(size.width * 0.3, size.height / 2, in: size) == .center)
        #expect(zone(size.width * 0.7, size.height / 2, in: size) == .center)
    }

    /// A small pane keeps all five targets: the edges are at least 48 pt (or a third), the
    /// center at least a third.
    @Test func smallPaneKeepsEveryTarget() {
        let size = CGSize(width: 160, height: 140)
        #expect(zone(80, 70, in: size) == .center)
        #expect(zone(45, 70, in: size) == .left)
        #expect(zone(115, 70, in: size) == .right)
        #expect(zone(80, 10, in: size) == .top)
        #expect(zone(80, 130, in: size) == .bottom)
    }

    /// A corner goes to the edge the pointer is relatively nearest: the diagonals of the body
    /// split it (FlexLayout, VS Code), not "left and right always win".
    @Test func cornersSplitOnTheDiagonal() {
        let size = CGSize(width: 1200, height: 800)
        #expect(zone(70, 10, in: size) == .top)
        #expect(zone(10, 70, in: size) == .left)
        #expect(zone(1190, 790 - 30, in: size) == .right)
    }

    /// A pointer resting on a zone line never flickers: the shown zone holds a few points past it.
    @Test func shownZoneHoldsNearItsLine() {
        let size = CGSize(width: 1200, height: 800)
        let line: CGFloat = 300
        #expect(zone(line + 4, 400, in: size, previous: .left) == .left)
        #expect(zone(line - 4, 400, in: size, previous: .center) == .center)
        #expect(zone(line + 40, 400, in: size, previous: .left) == .center)
    }

    var geometry: ScreenGeometry {
        ScreenGeometry(viewport: CGSize(width: 1200, height: 800),
                       panes: ["p": CGRect(x: 0, y: 0, width: 1200, height: 800)], contentWidth: 1200, isColumns: false)
    }

    /// Each shown dock holds 12 pt inward past its band, without entering either tab bar.
    @Test(arguments: [
        (DockEdge.top, PaneDropZone.top, CGPoint(x: 600, y: 74), CGPoint(x: 600, y: 75)),
        (.bottom, .bottom, CGPoint(x: 600, y: 744), CGPoint(x: 600, y: 743)),
        (.left, .left, CGPoint(x: 24, y: 400), CGPoint(x: 25, y: 400)),
        (.right, .right, CGPoint(x: 1176, y: 400), CGPoint(x: 1175, y: 400)),
    ])
    func shownDockHoldsNearItsLine(edge: DockEdge, zone: PaneDropZone, held: CGPoint, released: CGPoint) {
        let previous = DropTarget.newDock(screen: "s", edge: edge)
        #expect(DropZoneGeometry.dockTarget(atView: held, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20, previous: previous) == previous)
        #expect(DropZoneGeometry.dockTarget(atView: released, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20, previous: previous) == nil)
        #expect(DropZoneGeometry.dockTarget(atView: held, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20) == nil)
        #expect(DropZoneGeometry.target(atView: released, offset: 0, screen: "s", geometry: geometry,
                                        style: style, previous: previous) == .pane("p", zone))
    }

    /// Entering a dock from the split zone facing it needs half a band (up to 12 pt); from any
    /// other target, or none, the band keeps its depth.
    @Test(arguments: [
        (DockEdge.top, PaneDropZone.top, CGPoint(x: 600, y: 55), CGPoint(x: 600, y: 49)),
        (.bottom, .bottom, CGPoint(x: 600, y: 761), CGPoint(x: 600, y: 769)),
        (.left, .left, CGPoint(x: 9, y: 400), CGPoint(x: 5, y: 400)),
        (.right, .right, CGPoint(x: 1191, y: 400), CGPoint(x: 1195, y: 400)),
    ])
    func paneEdgeDoesNotFlipToDock(edge: DockEdge, zone: PaneDropZone, near: CGPoint, inside: CGPoint) {
        let dock = DropTarget.newDock(screen: "s", edge: edge)
        #expect(DropZoneGeometry.dockTarget(atView: near, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20, previous: .pane("p", zone)) == nil)
        #expect(DropZoneGeometry.dockTarget(atView: inside, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20, previous: .pane("p", zone)) == dock)
        for previous in [DropTarget.pane("p", .center), .newColumn(screen: "s", after: nil), .newDock(screen: "other", edge: edge)] {
            #expect(DropZoneGeometry.dockTarget(atView: near, screen: "s", geometry: geometry, style: style,
                                                topInset: 30, bottomInset: 20, previous: previous) == dock)
        }
        #expect(DropZoneGeometry.target(atView: near, offset: 0, screen: "s", geometry: geometry,
                                        style: style, previous: .pane("p", zone)) == .pane("p", zone))
        #expect(DropZoneGeometry.dockTarget(atView: near, screen: "s", geometry: geometry, style: style,
                                            topInset: 30, bottomInset: 20) == dock)
    }

    @Test func dockHysteresisPreservesTabBarsAndCornerOrder() {
        for (point, edge) in [(CGPoint(x: 600, y: 29), DockEdge.top), (CGPoint(x: 600, y: 781), .bottom)] {
            #expect(DropZoneGeometry.dockTarget(atView: point, screen: "s", geometry: geometry, style: style,
                                                topInset: 30, bottomInset: 20, previous: .newDock(screen: "s", edge: edge)) == nil)
        }
        #expect(DropZoneGeometry.dockTarget(atView: CGPoint(x: 2, y: 35), screen: "s", geometry: geometry, style: style,
                                            topInset: 30, previous: .newDock(screen: "s", edge: .left)) == .newDock(screen: "s", edge: .top))
    }

    /// Both coordinate paths hold a shown gap 12 pt horizontally, and shrink entry from a left or
    /// right split zone by width / 4; entry from anything else keeps the frame.
    @Test(arguments: [CGFloat(0), CGFloat(75)])
    func columnGapHysteresis(offset: CGFloat) {
        var geometry = self.geometry
        geometry.gapZones = [ColumnGapZone(after: "c", frame: CGRect(x: 282, y: 0, width: 36, height: 800))]
        let gap = DropTarget.newColumn(screen: "s", after: "c")
        func target(_ x: CGFloat, previous: DropTarget? = nil, inView: Bool) -> DropTarget? {
            let point = CGPoint(x: x, y: 400)
            if inView {
                return DropZoneGeometry.target(atView: CGPoint(x: x - offset, y: point.y), offset: offset, screen: "s",
                                               geometry: geometry, style: style, previous: previous)
            }
            return DropZoneGeometry.target(at: point, screen: "s", geometry: geometry, style: style, previous: previous)
        }
        for inView in [false, true] {
            for x: CGFloat in [270, 329] {
                #expect(target(x, previous: gap, inView: inView) == gap)
            }
            #expect(target(269, previous: gap, inView: inView) == .pane("p", .left))
            #expect(target(331, previous: gap, inView: inView) == .pane("p", .center))
            for previous in [DropTarget.pane("p", .left), .pane("p", .right)] {
                #expect(target(286, previous: previous, inView: inView) == .pane("p", .left))
                #expect(target(314, previous: previous, inView: inView) == .pane("p", .center))
                #expect(target(292, previous: previous, inView: inView) == gap)
                #expect(target(308, previous: previous, inView: inView) == gap)
            }
            for previous in [DropTarget.pane("p", .center), .newDock(screen: "s", edge: .left),
                             .newColumn(screen: "s", after: nil), .newColumn(screen: "other", after: "c")] {
                #expect(target(283, previous: previous, inView: inView) == gap)
                #expect(target(317, previous: previous, inView: inView) == gap)
            }
            #expect(target(283, inView: inView) == gap)
            #expect(target(317, inView: inView) == gap)
            #expect(target(281, inView: inView) == .pane("p", .left))
            #expect(target(319, inView: inView) == .pane("p", .center))
        }
    }
}
