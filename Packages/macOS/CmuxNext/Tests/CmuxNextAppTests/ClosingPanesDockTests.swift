import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// CLOSE MOTION 2 case E (cmux-ad m48): the last tab of a docked pane closes its pane, and the strip pane beside it grows
/// over its place on the pane-close spring. The docked pane closes as one unit: it keeps showing its ground on the space
/// the strip pane has not covered yet, so no frame shows the window background where it was (before: it found no
/// neighbour, since a docked pane and a strip pane are in different coordinates, and hid in the close's turn).
struct ClosingPanesDockTests {
    /// A strip pane (1) and a pane docked at the right (2), 6 pt apart, with the dock's column edge between them; the
    /// close takes the dock's edge away.
    static let strip = ClosingPanesRules.PaneFact(id: 1, edges: .init(minX: 0, maxX: 600, minY: 0, maxY: 800), scrolls: true, area: 0,
                                                  rowColumn: 0)
    static let dock = ClosingPanesRules.PaneFact(id: 2, edges: .init(minX: 606, maxX: 900, minY: 0, maxY: 800), scrolls: false, area: 0,
                                                 rowColumn: 0)
    static let dockEdge = ClosingPanesRules.HandleFact(kind: .columnEdge, horizontal: true, hit: .init(minX: 600, maxX: 606, minY: 0, maxY: 800),
                                                       midX: 603, midY: 400, kept: false, fixedSplit: false, area: 0, docked: true, column: 0)

    static func growing(to maxX: CGFloat, shift: CGFloat = 0) -> ClosingPanesRules.FrameFact {
        .init(id: 1, now: .init(minX: -shift, maxX: maxX - shift, minY: 0, maxY: 800), target: .init(minX: -shift, maxX: 900 - shift, minY: 0, maxY: 800),
              moving: maxX != 900, vx: 0, vy: 0, vw: maxX != 900 ? 400 : 0, vh: 0, scrolls: true)
    }

    /// The strip pane's x in strip coordinates: the view's minus the strip's view shift `shift`.
    static func inStrip(_ pane: ClosingPanesRules.PaneFact, shift: CGFloat) -> ClosingPanesRules.PaneFact {
        var pane = pane
        pane.edges.minX -= shift
        pane.edges.maxX -= shift
        return pane
    }

    @Test(arguments: [0, 120, -75] as [CGFloat])
    func dockedPaneClosesUnderTheStripPaneThatGrowsOverIt(shift: CGFloat) {
        var rules = ClosingPanesRules()
        let began = rules.begin(2, shown: Self.dock.edges, panes: [Self.inStrip(Self.strip, shift: shift), Self.dock], handles: [Self.dockEdge],
                                maxGap: 11, viewShift: nil, stripShift: shift)
        #expect(began)
        // The strip pane springs over the dock's place: the docked pane does not hide in the close's turn.
        let hidden = rules.settle(frames: [Self.growing(to: 600, shift: shift)], rows: [])
        #expect(hidden == [])
        #expect(rules.entries[2]?.minX.neighbours == [1])
        // Its leading side rides the strip pane's trailing edge where it shows (the dock's edge goes, so no gap stays).
        let mid = rules.rects(frames: [Self.growing(to: 750, shift: shift)], rows: [], strip: shift, restStrip: shift)
        #expect(mid.first?.0 == 2)
        #expect(mid.first?.1 == ClosingPanesRules.Placed(x: 750, y: 0, width: 150, height: 800))
        let landed = rules.rects(frames: [Self.growing(to: 900, shift: shift)], rows: [], strip: shift, restStrip: shift)
        #expect(landed.first?.1.width == 0)
    }

    /// A strip pane closing beside the dock finds the docked pane across the strip's view shift as well.
    @Test func stripPaneFindsTheDockedPaneBesideIt() {
        var rules = ClosingPanesRules()
        let began = rules.begin(1, shown: Self.inStrip(Self.strip, shift: 120).edges, panes: [Self.inStrip(Self.strip, shift: 120), Self.dock],
                                handles: [Self.dockEdge], maxGap: 11, viewShift: nil, stripShift: 120)
        #expect(began)
        #expect(rules.entries[1]?.maxX.neighbours == [2])
    }
}
