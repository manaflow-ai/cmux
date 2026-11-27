import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RFD 0199 §4 (cmuxterm-hq): one divider drag tick should cost what the drag moved, not the whole screen.
/// Leo, 2026-11-27: "wonder if we can get some ds&a proper for those situations? like among various parts of the app
/// that could be liable to perf situatoins or whatever".
///
/// Each case builds a screen of N panes (a balanced tree with alternating axes, or a same-axis chain), drags the
/// deepest split's handle through the real path (`DividerHandleView` events, the model's turn, one frame tick), and
/// counts what that one tick did with `LayoutOpCount`: split tree nodes visited, pane frames placed and pane shapes
/// applied. `k` is the number of panes whose target frame the tick changed, read from the screen's geometry.
///
/// Op counts only, no wall clock: it runs on any Mac. The wall budget is `LayoutDragBench`'s (8.33 ms a move).
///
/// Today every tick lays out the whole screen and places and shapes every pane, so the bound is a known issue until
/// the incremental layout tree lands (RFD 0199 §4 spec, steps 1-2); that change drops the `withKnownIssue`.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct LayoutIncrementalBoundTests {
    enum Shape: String, CaseIterable, Sendable { case balanced, chain }

    struct Tree {
        var root: SplitNode
        /// The deepest split whose children are both panes: the divider the test drags.
        var dragged: SplitID
        /// Splits from the root to `dragged`, inclusive.
        var depth: Int
    }

    /// `count` panes: halves split on alternating axes, or one horizontal chain.
    static func tree(_ shape: Shape, panes count: Int) -> Tree {
        var nextPane = 0, nextSplit = 0
        var deepest: (id: SplitID, depth: Int)?
        func build(_ n: Int, depth: Int, axis: SplitAxis) -> SplitNode {
            if n == 1 {
                nextPane += 1
                return .leaf(PaneID("p\(nextPane)"))
            }
            nextSplit += 1
            let id = SplitID("s\(nextSplit)")
            let left = shape == .balanced ? n / 2 : 1
            let next: SplitAxis = shape == .balanced ? (axis == .horizontal ? .vertical : .horizontal) : axis
            let a = build(left, depth: depth + 1, axis: next)
            let b = build(n - left, depth: depth + 1, axis: next)
            if case .leaf = a, case .leaf = b, depth >= (deepest?.depth ?? 0) { deepest = (id, depth) }
            return .split(id, axis: axis, ratio: Double(left) / Double(n), a: a, b: b)
        }
        let root = build(count, depth: 1, axis: .horizontal)
        return Tree(root: root, dragged: deepest!.id, depth: deepest!.depth)
    }

    struct Tick {
        var visits = 0, places = 0, shapes = 0, moved = 0, reconciles = 0
    }

    /// One measured drag tick on `tree` in a window big enough that the dragged panes keep their minimums.
    static func dragTick(_ tree: Tree) async throws -> Tick {
        let probe = LayoutWorkProbe(.columns([LayoutColumn(id: "c0", width: 1, root: tree.root)]),
                                    size: CGSize(width: 4000, height: 2400), focused: "p1")
        defer { probe.close() }
        let screen = probe.screen
        let handle = try #require(screen.dividerViews[.split(tree.dragged)], "no handle for \(tree.dragged)")
        let start = screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
        let axisX = screen.geometry.dividers.first { $0.id == tree.dragged }?.axis == .horizontal
        func point(_ offset: CGFloat) -> CGPoint { axisX ? CGPoint(x: start.x + offset, y: start.y) : CGPoint(x: start.x, y: start.y + offset) }
        handle.mouseDown(with: probe.event(.leftMouseDown, start))
        await DividerDragFrameTickTests.turns()
        // A first move and its tick: the gesture's start (the catch, the model's gesture flag) is not the steady tick.
        handle.mouseDragged(with: probe.event(.leftMouseDragged, point(-6)))
        await DividerDragFrameTickTests.turns()
        _ = probe.root.advanceFrame(1.0 / 120)
        await DividerDragFrameTickTests.turns()

        let before = screen.baseGeometry.panes
        let passes = screen.reconcilePasses
        let count = LayoutOpCount()
        await LayoutOpCount.$current.withValue(count) {
            handle.mouseDragged(with: probe.event(.leftMouseDragged, point(-12)))
            await DividerDragFrameTickTests.turns()
            _ = probe.root.advanceFrame(1.0 / 120)
            await DividerDragFrameTickTests.turns()
        }
        let after = screen.baseGeometry.panes
        let counted = count.value
        let tick = Tick(visits: counted.visits, places: counted.places, shapes: counted.shapes,
                        moved: after.filter { before[$0.key] != $0.value }.count, reconciles: screen.reconcilePasses - passes)
        handle.mouseUp(with: probe.event(.leftMouseUp, point(-12)))
        await DividerDragFrameTickTests.turns()
        probe.settle()
        return tick
    }

    @Test func dragTickTouchesDepthNotScreen() async throws {
        var balancedVisits: [Int: Int] = [:]
        for shape in Shape.allCases {
            for panes in [20, 200] {
                let tree = Self.tree(shape, panes: panes)
                let tick = try await Self.dragTick(tree)
                print("LAYOUT-BOUND tree=\(shape.rawValue) n=\(panes) depth=\(tree.depth) k=\(tick.moved) visits=\(tick.visits)"
                    + " places=\(tick.places) shapes=\(tick.shapes) reconciles=\(tick.reconciles)")
                // What holds now: the tick ran the layout and moved the two dragged panes. A 200-pane chain cannot keep
                // its minimums in any window (its panes share the width in proportion), so its divider does not move.
                #expect(tick.reconciles >= 1, "\(shape) n=\(panes): the drag tick did not reconcile")
                if !(shape == .chain && panes == 200) {
                    #expect(tick.moved >= 2, "\(shape) n=\(panes): the drag tick moved \(tick.moved) panes, not the dragged two")
                }
                if shape == .balanced { balancedVisits[panes] = tick.visits }
                let k = tick.moved
                withKnownIssue("RFD 0199 §4: each drag tick lays out and shapes the whole screen", isIntermittent: true) {
                    #expect(tick.visits <= 4 * (tree.depth + k), "\(shape) n=\(panes): \(tick.visits) node visits for depth \(tree.depth), k \(k)")
                    #expect(tick.shapes <= k, "\(shape) n=\(panes): \(tick.shapes) shape applies for \(k) moved panes")
                    #expect(tick.places <= k, "\(shape) n=\(panes): \(tick.places) frame places for \(k) moved panes")
                }
            }
        }
        let ratio = Double(balancedVisits[200] ?? 0) / Double(max(balancedVisits[20] ?? 1, 1))
        print("LAYOUT-BOUND balanced visits_200_over_20=\(String(format: "%.2f", ratio))")
        withKnownIssue("RFD 0199 §4: visits grow with the screen, not the dragged split", isIntermittent: true) {
            #expect(ratio <= 1.5, "balanced: 200 panes cost \(ratio)x the node visits of 20")
        }
    }
}
