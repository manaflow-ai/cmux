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
}
