import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// R47 (Lawrence 2026-10-03: drop zones for split left/right/top/bottom are
/// sometimes wrong). The zones are measured on the pane body below its tab
/// bar, the part the drop preview divides, not on the whole cell: the tab
/// bar belongs to the strip (join), and a short pane keeps a center.
/// Before, the bands started at the cell top (the strip covers the first
/// ~32 pt of the top band) and could cover a short pane completely.
@Suite struct DropZoneModelTests {
    private let style = LayoutStyle()
    /// A 400 x 300 pane with a 32 pt tab bar: the body is 400 x 268 at y 32.
    private let cell = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let header: CGFloat = 32

    private func zone(_ x: CGFloat, _ y: CGFloat, in rect: CGRect? = nil) -> PaneDropZone {
        DropZoneGeometry.zone(at: CGPoint(x: x, y: y), in: rect ?? cell, header: header, style: style)
    }

    @Test func theTabBarAreaJoinsThePane() {
        #expect(zone(200, 10) == .center)
        #expect(zone(5, 10) == .center)
        #expect(zone(395, 31) == .center)
    }

    @Test func theTopBandStartsBelowTheTabBar() {
        // Body band: 268 * 0.28 = 75 pt, from y 32.
        #expect(zone(200, 33) == .top)
        #expect(zone(200, 32 + 74) == .top)
        #expect(zone(200, 32 + 76) == .center)
    }

    @Test func sideAndBottomBandsUseTheBody() {
        // Side band 400 * 0.28 = 112 pt; bottom band 75 pt from y 300.
        #expect(zone(111, 166) == .left)
        #expect(zone(113, 166) == .center)
        #expect(zone(289, 166) == .right)
        #expect(zone(200, 300 - 74) == .bottom)
        #expect(zone(200, 300 - 76) == .center)
    }

    @Test func aShortPaneKeepsACenter() {
        // A 70 pt pane: 38 pt of body. The middle of the body joins it.
        let short = CGRect(x: 0, y: 0, width: 400, height: 70)
        #expect(zone(200, 51, in: short) == .center)
        #expect(zone(200, 34, in: short) == .top)
        #expect(zone(200, 69, in: short) == .bottom)
    }

    @Test func aNarrowPaneKeepsACenter() {
        let narrow = CGRect(x: 0, y: 0, width: 60, height: 300)
        #expect(zone(30, 166, in: narrow) == .center)
        #expect(zone(2, 166, in: narrow) == .left)
        #expect(zone(58, 166, in: narrow) == .right)
    }

    @Test func theScreenTargetUsesEachPanesTabBar() {
        let geometry = ScreenGeometry.compute(.splits(.leaf("a")), viewport: CGSize(width: 400, height: 300), style: style)
        let a = geometry.panes["a"]!
        let tabBar = CGPoint(x: a.midX, y: a.minY + 10)
        #expect(DropZoneGeometry.target(at: tabBar, screen: "s", geometry: geometry, headers: ["a": header], style: style)
            == .pane("a", .center))
        #expect(DropZoneGeometry.target(atView: tabBar, offset: 0, screen: "s", geometry: geometry, headers: ["a": header],
                                        style: style) == .pane("a", .center))
    }

    @Test func aDockedColumnsPaneUsesItsTabBarToo() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c0", width: 0.3, root: .leaf("p0"), sticky: StickyColumn(edge: .left, mode: .docked)),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
        ])
        let geometry = ScreenGeometry.compute(layout, viewport: CGSize(width: 1000, height: 600), style: style, scale: 2)
        let docked = geometry.panes["p0"]!
        let point = CGPoint(x: docked.midX, y: docked.minY + 10)
        #expect(DropZoneGeometry.target(atView: point, offset: 0, screen: "s", geometry: geometry, headers: ["p0": header],
                                        style: style) == .pane("p0", .center))
    }
}
