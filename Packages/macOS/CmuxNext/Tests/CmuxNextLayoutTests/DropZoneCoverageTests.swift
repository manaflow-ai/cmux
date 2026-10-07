import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// tab-dnd (Lawrence 2026-10-04: "at every point when im dragging, there
/// should be a drop zone preview. rn some points where i drag dont show it
/// and tab goes back to where it was after i drop it"). Property over a
/// point grid of several layouts: every point of the screen view resolves
/// to a drop target with a preview rect, and each target's points form one
/// 4-connected region (no islands, so the outline never jumps back and
/// forth while the pointer moves in one direction). Before the fix the gaps
/// between panes, the pane padding and a docked column's rim resolved to
/// nothing: no preview, and the drop sprang back.
@Suite struct DropZoneCoverageTests {
    let style = LayoutStyle()
    let viewport = CGSize(width: 1000, height: 600)
    let step: CGFloat = 4

    struct Case {
        var name: String
        var layout: ScreenLayout
        var offset: CGFloat = 0
        var headers: [PaneID: CGFloat] = [:]
    }

    var cases: [Case] {
        let splits = SplitNode.split("s", axis: .horizontal, ratio: 0.4, a: .leaf("a"),
                                     b: .split("t", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        let columns: [LayoutColumn] = [
            LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")),
            LayoutColumn(id: "c1", width: 0.5, root: .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("p3")),
        ]
        var overlay = columns
        overlay[2].width = 0.3
        overlay[2].dock = DockColumn(edge: .right, mode: .overlay)
        var docked = columns
        docked[0].width = 0.3
        docked[0].dock = DockColumn(edge: .left, mode: .docked)
        let headers: [PaneID: CGFloat] = ["a": 32, "b": 32, "c": 32, "p0": 32, "p1": 32, "p2": 32, "p3": 32]
        return [
            Case(name: "one pane", layout: .splits(.leaf("a")), headers: ["a": 32]),
            Case(name: "nested splits", layout: .splits(splits), headers: headers),
            Case(name: "columns", layout: .columns(columns), headers: headers),
            Case(name: "columns scrolled", layout: .columns(columns), offset: 180, headers: headers),
            Case(name: "overlay dock", layout: .columns(overlay), headers: headers),
            Case(name: "docked column", layout: .columns(docked), headers: headers),
        ]
    }

    private func grid() -> [CGPoint] {
        var points: [CGPoint] = []
        var y: CGFloat = 0.5
        while y < viewport.height {
            var x: CGFloat = 0.5
            while x < viewport.width {
                points.append(CGPoint(x: x, y: y))
                x += step
            }
            y += step
        }
        return points
    }

    @Test func everyPointOfTheScreenResolvesToATargetWithAPreview() {
        for item in cases {
            let geometry = ScreenGeometry.compute(item.layout, viewport: viewport, style: style, scale: 2)
            var holes: [CGPoint] = []
            for point in grid() {
                guard let target = DropZoneGeometry.target(atView: point, offset: item.offset, screen: "s", geometry: geometry,
                                                           headers: item.headers, style: style),
                      let rect = DropZoneGeometry.highlightRectInView(for: target, offset: item.offset, geometry: geometry, style: style),
                      !rect.isEmpty
                else {
                    holes.append(point)
                    continue
                }
            }
            #expect(holes.isEmpty, "\(item.name): \(holes.count) points resolve to no target, first \(holes.prefix(4))")
        }
    }

    /// Without tab bars: a pane's tab bar joins the pane (center) by design
    /// (R47), and in the app the strip above takes those points first, so
    /// the bar is checked by the coverage test, not here.
    @Test func eachTargetCoversOneConnectedRegion() {
        let columns = Int((viewport.width / step).rounded(.up))
        for item in cases {
            let geometry = ScreenGeometry.compute(item.layout, viewport: viewport, style: style, scale: 2)
            let points = grid()
            let labels = points.map {
                DropZoneGeometry.target(atView: $0, offset: item.offset, screen: "s", geometry: geometry, style: style)
            }
            var seen = Set<Int>()
            var regions: [DropTarget: Int] = [:]
            for start in labels.indices where !seen.contains(start) {
                guard let label = labels[start] else { continue }
                regions[label, default: 0] += 1
                var stack = [start]
                seen.insert(start)
                while let index = stack.popLast() {
                    let row = index / columns, column = index % columns
                    let neighbors = [(row - 1, column), (row + 1, column), (row, column - 1), (row, column + 1)]
                    for (r, c) in neighbors where r >= 0 && c >= 0 && c < columns {
                        let next = r * columns + c
                        guard next < labels.count, !seen.contains(next), labels[next] == label else { continue }
                        seen.insert(next)
                        stack.append(next)
                    }
                }
            }
            let split = regions.filter { $0.value > 1 }
            #expect(split.isEmpty, "\(item.name): targets in several islands: \(split)")
        }
    }

    /// The gutter between two panes previews a split of the nearer pane,
    /// at the edge the pointer is on (no dead strip between them).
    @Test func theGutterBetweenTwoPanesSplitsTheNearerOne() {
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
        let geometry = ScreenGeometry.compute(.splits(tree), viewport: viewport, style: style, scale: 2)
        let a = geometry.panes["a"]!, b = geometry.panes["b"]!
        #expect(b.minX > a.maxX, "the test needs a gutter")
        let y = a.midY
        let nearA = DropZoneGeometry.target(atView: CGPoint(x: a.maxX + 0.25, y: y), offset: 0, screen: "s", geometry: geometry, style: style)
        let nearB = DropZoneGeometry.target(atView: CGPoint(x: b.minX - 0.25, y: y), offset: 0, screen: "s", geometry: geometry, style: style)
        #expect(nearA == .pane("a", .right))
        #expect(nearB == .pane("b", .left))
    }
}
