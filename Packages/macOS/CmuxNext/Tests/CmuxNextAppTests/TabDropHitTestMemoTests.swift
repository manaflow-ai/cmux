import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Testing

/// HOT PATH AUDIT frames (drag-frame): a tab drag over a pane edge asks the screen for its drop target on every pointer
/// move. Each ask computed the geometry of the whole screen twice (the room check `SplitRoom.placement` on a columns
/// screen, and the edge preview's predicted layout), also when the pointer stayed in the same zone of the same pane and
/// nothing in the layout changed. Both answers depend only on the layout, the viewport, the style and the target: they
/// are computed once per target and layout, and a pointer move inside the zone computes nothing.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabDropHitTestMemoTests {
    /// A point in `pane`'s edge zone (any side), and its target.
    private func edgePoint(_ screen: ScreenContentView, _ pane: PaneID) -> (NSPoint, DropTarget)? {
        guard let frame = screen.displayedFrame(of: pane) else { return nil }
        for fy in stride(from: 0.05, through: 0.95, by: 0.05) {
            for fx in [0.04, 0.96, 0.5] {
                let point = NSPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
                if let hit = screen.dropTarget(at: point), case let .pane(target, zone) = hit.target, target == pane, zone != .center {
                    return (point, hit.target)
                }
            }
        }
        return nil
    }

    @Test func pointerMovesInsideOneEdgeZoneComputeNoGeometry() throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let (point, target) = try #require(edgePoint(screen, PaneID("p1-1")), "no edge zone found on p1-1")
        _ = screen.dropTarget(at: point)
        let before = screen.dropGeometryComputes
        var same = 0
        for step in 1...30 {
            let moved = NSPoint(x: point.x + CGFloat(step % 3) * 0.5, y: point.y + CGFloat(step % 2) * 0.5)
            if screen.dropTarget(at: moved)?.target == target { same += 1 }
        }
        let computes = screen.dropGeometryComputes - before
        print("HPA-COUNT case=drop-hit-test panes=12 moves=30 same_target=\(same) geometry_computes=\(computes)")
        try #require(same == 30, "the pointer left the zone: \(same) of 30 moves kept \(target)")
        #expect(computes == 0, "30 moves inside one edge zone computed the screen's geometry \(computes) times")
    }

    @Test func aLayoutChangeComputesTheAnswerAgain() async throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let (point, _) = try #require(edgePoint(screen, PaneID("p1-1")))
        let first = screen.dropTarget(at: point)
        var next = columns
        next[2] = PaneMotionBench.column(2, rows: 2, width: 0.25)
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() } // the model's observation turn: the screen takes the new layout
        probe.settle()
        let before = screen.dropGeometryComputes
        let again = screen.dropTarget(at: point)
        #expect(screen.dropGeometryComputes > before, "a new layout must not answer from the old layout's preview")
        #expect(again?.target == first?.target)
    }
}
