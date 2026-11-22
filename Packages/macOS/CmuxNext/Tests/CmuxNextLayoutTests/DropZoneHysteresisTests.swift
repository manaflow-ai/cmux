import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// op-next-split (Leo 2026-10-06: "cmux-next is kinda fucked up on
/// splitting"). A tab held near a zone line made the preview flip between
/// the two zones on every pointer jitter, and in a pane's corner it flipped
/// between top and left within a few points. The zone the preview shows now
/// holds until the pointer is `dropZoneHysteresis` past its line.
@Suite struct DropZoneHysteresisTests {
    private let style = LayoutStyle()
    /// A 400 x 300 pane with a 32 pt tab bar: the body is 400 x 268 at y 32.
    /// Side bands are 112 pt (400 * 0.28), top and bottom 75 pt.
    private let cell = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let header: CGFloat = 32

    private func zone(_ x: CGFloat, _ y: CGFloat, previous: PaneDropZone?) -> PaneDropZone {
        DropZoneGeometry.zone(at: CGPoint(x: x, y: y), in: cell, header: header, style: style, previous: previous)
    }

    @Test func theCenterHoldsUntilThePointerIsWellInsideAnEdgeBand() {
        #expect(zone(108, 166, previous: .center) == .center)
        #expect(zone(95, 166, previous: .center) == .left)
        #expect(zone(108, 166, previous: nil) == .left)
    }

    @Test func anEdgeHoldsUntilThePointerIsWellPastItsLine() {
        #expect(zone(118, 166, previous: .left) == .left)
        #expect(zone(130, 166, previous: .left) == .center)
        #expect(zone(118, 166, previous: nil) == .center)
    }

    @Test func aCornerHoldsTheEdgeItShows() {
        // Relatively nearer the top edge: top without a previous zone.
        #expect(zone(40, 32 + 25, previous: nil) == .top)
        #expect(zone(40, 32 + 25, previous: .left) == .left)
        // Clearly nearer the top: the preview moves.
        #expect(zone(60, 32 + 10, previous: .left) == .top)
    }

    @Test func theTabBarStillJoinsThePaneWhateverWasShown() {
        #expect(zone(5, 10, previous: .left) == .center)
    }

    @Test func thePreviousZoneOnlyHoldsItsOwnPane() {
        let geometry = ScreenGeometry.compute(.splits(.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))),
                                              viewport: CGSize(width: 800, height: 300), style: style)
        let a = geometry.panes["a"]!
        // Just inside a's right band, from the center of a: a's center holds.
        let band = DropZoneGeometry.band(for: a.width, style: style)
        let point = CGPoint(x: a.maxX - band + 4, y: a.midY)
        func target(_ previous: DropTarget?) -> DropTarget? {
            DropZoneGeometry.target(atView: point, offset: 0, screen: "s", geometry: geometry, style: style, previous: previous)
        }
        #expect(target(nil) == .pane("a", .right))
        #expect(target(.pane("a", .center)) == .pane("a", .center))
        // A zone shown in another pane does not bias this one.
        #expect(target(.pane("b", .center)) == .pane("a", .right))
    }
}
