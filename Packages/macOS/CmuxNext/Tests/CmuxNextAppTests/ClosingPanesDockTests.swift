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

    static func growing(to maxX: CGFloat) -> ClosingPanesRules.FrameFact {
        .init(id: 1, now: .init(minX: 0, maxX: maxX, minY: 0, maxY: 800), target: .init(minX: 0, maxX: 900, minY: 0, maxY: 800),
              moving: maxX != 900, vx: 0, vy: 0, vw: maxX != 900 ? 400 : 0, vh: 0)
    }

    @Test func dockedPaneClosesUnderTheStripPaneThatGrowsOverIt() {
        var rules = ClosingPanesRules()
        let began = rules.begin(2, shown: Self.dock.edges, panes: [Self.strip, Self.dock], handles: [Self.dockEdge], maxGap: 11, viewShift: nil)
        #expect(began)
        // The strip pane springs over the dock's place: the docked pane does not hide in the close's turn.
        let hidden = rules.settle(frames: [Self.growing(to: 600)], rows: [])
        #expect(hidden == [])
        #expect(rules.entries[2]?.minX.neighbours == [1])
        // Its leading side rides the strip pane's trailing edge (the dock's edge goes, so no gap stays).
        let mid = rules.rects(frames: [Self.growing(to: 750)], rows: [])
        #expect(mid.first?.0 == 2)
        #expect(mid.first?.1 == ClosingPanesRules.Placed(x: 750, y: 0, width: 150, height: 800))
        let landed = rules.rects(frames: [Self.growing(to: 900)], rows: [])
        #expect(landed.first?.1.width == 0)
    }
}
