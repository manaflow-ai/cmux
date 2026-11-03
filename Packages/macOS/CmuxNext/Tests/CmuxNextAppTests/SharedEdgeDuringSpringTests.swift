import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S2B: two panes that share an edge show it at the same place in every frame, also when two
/// motions overlap: their gap is the gap at rest, never wider (the shell shows between them) and never narrower (they
/// overlap), and a divider a person drags stays under the pointer.
///
/// Each pane frame and each divider frame is its own spring (`AnimatedFrame`). They agree only while they all step
/// together from consistent values. A drag snaps every frame it retargets to its target (`ScreenContentView.place`,
/// M3) while a frame it does not retarget keeps its spring: when a drag starts during a key resize's spring, the
/// dragged column's panes jump to their rest place and the springing column beside them is still on its way. A drag
/// also starts from the rest geometry (`DividerDrag.start`), not from where a springing divider shows.
///
/// Three cases on one layout, A | B (split x: b1 | b2) | C, a strip that fits its viewport:
/// - a key press grows column A (its edge springs) and, while it springs, a drag starts on B's column edge;
/// - the same, with the drag on the split divider inside B;
/// - a Shift drag of the split divider lands on a snap (its release springs) and, while that springs, a key press
///   grows column A.
/// The test is the display clock (`driver.isManual`, 120 Hz) and checks every frame tick.
@MainActor
@Suite(.closesItsWindows)
struct SharedEdgeDuringSpringTests {
    enum Overlap: String, CaseIterable, Sendable {
        case keySpringThenColumnEdgeDrag, keySpringThenSplitDrag, releaseSpringThenKeyPress
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Two panes whose rest frames share a vertical edge, and the gap between them at rest.
    struct SharedEdge {
        var left: PaneID
        var right: PaneID
        var rest: CGFloat
    }

    @MainActor
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every frame tick (and the release) where a shared edge or the dragged divider was off.
        var misses: [String] = []
        var ticks = 0

        init() {
            _ = NSApplication.shared
            let columns = [
                LayoutColumn(id: "A", width: 0.3, root: .leaf("a")),
                LayoutColumn(id: "B", width: 0.4, root: .split("x", axis: .horizontal, ratio: 0.3, a: .leaf("b1"), b: .leaf("b2"))),
                LayoutColumn(id: "C", width: 0.2, root: .leaf("c")),
            ]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            while root.advanceFrame(1.0 / 120) {}
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        func handle(_ kind: DividerHandleView.Kind) throws -> DividerHandleView {
            try #require(try screen.dividerViews[kind], "no handle \(kind)")
        }

        /// The middle of `kind`'s handle as it shows now, in window coordinates.
        func center(_ kind: DividerHandleView.Kind) throws -> CGPoint {
            let view = try handle(kind)
            return view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// The pairs of panes that share a vertical edge at rest, with their rest gaps, from the host frames shown.
        func sharedEdges() throws -> [SharedEdge] {
            let shown = try screen.layout.panes.compactMap { pane in root.context.hosts[pane].map { (pane, $0.frame) } }
            var edges: [SharedEdge] = []
            for (left, l) in shown {
                for (right, r) in shown where right != left {
                    let gap = r.minX - l.maxX
                    if gap >= 0, gap <= 24, min(l.maxY, r.maxY) - max(l.minY, r.minY) > 1 {
                        edges.append(SharedEdge(left: left, right: right, rest: gap))
                    }
                }
            }
            return edges
        }

        /// Half a device pixel and float slack: the farthest a divider that follows the pointer may show from it.
        var halfPixel: CGFloat { get throws { 0.5 / max(try screen.scale, 1) + 0.01 } }

        /// Records each shared edge whose gap is not its rest gap, as the screen shows it now.
        func check(_ edges: [SharedEdge], _ label: String) {
            for edge in edges {
                guard let l = root.context.hosts[edge.left]?.frame, let r = root.context.hosts[edge.right]?.frame else { continue }
                let gap = r.minX - l.maxX
                if abs(gap - edge.rest) > 0.001 {
                    misses.append("\(label): \(edge.left)|\(edge.right) gap \(Self.pt(gap)) pt, at rest \(Self.pt(edge.rest)) pt")
                }
            }
        }

        /// One display frame, then the check.
        func frame(_ edges: [SharedEdge], _ label: String) {
            _ = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            ticks += 1
            check(edges, label)
        }

        /// The right edge of `pane` as the screen shows it (its host's frame).
        func rightEdge(_ pane: PaneID) throws -> CGFloat {
            try #require(root.context.hosts[pane], "no host for \(pane)").frame.maxX
        }

        /// A drag of `kind`, pressed where its handle shows, `moves` steps of `step` points (whole points: the edge
        /// stays on the pixel grid), one display frame per move. In every frame it checks the shared edges, and that
        /// the dragged edge (the right edge of `dragged`) moved with the pointer from where it showed at the press;
        /// then the release.
        func drag(_ kind: DividerHandleView.Kind, dragged: PaneID, moves: Int, step: CGFloat, flags: NSEvent.ModifierFlags = [],
                  edges: [SharedEdge]) throws {
            let view = try handle(kind)
            let press = try center(kind)
            let tolerance = try halfPixel
            let start = try rightEdge(dragged)
            view.mouseDown(with: event(.leftMouseDown, press, flags))
            var pointer = press
            for move in 1...moves {
                pointer.x += step
                view.mouseDragged(with: event(.leftMouseDragged, pointer, flags))
                frame(edges, "drag frame \(move)")
                let shown = try rightEdge(dragged), want = start + CGFloat(move) * step
                if abs(shown - want) > tolerance {
                    misses.append("drag frame \(move): the dragged edge shows at \(Self.pt(shown)), the pointer put it at \(Self.pt(want))")
                }
            }
            view.mouseUp(with: event(.leftMouseUp, pointer, flags))
            root.syncWithModel()
            check(edges, "release")
        }

        /// Display frames until nothing moves (at most 2 s of them), each checked.
        func land(_ edges: [SharedEdge], _ label: String) {
            var frames = 0
            while frames < 240 {
                frames += 1
                let moving = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                ticks += 1
                check(edges, "\(label) frame \(frames)")
                if !moving { break }
            }
        }

        static func pt(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    }

    @Test(arguments: Overlap.allCases)
    func panesThatShareAnEdgeShowItAtOnePlaceInEveryFrame(_ overlap: Overlap) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        // a|b1 and b2|c (column gaps) and b1|b2 (the split's divider gap).
        try #require(edges.count == 3, "shared edges at rest: \(edges.map { "\($0.left)|\($0.right)" })")

        switch overlap {
        case .keySpringThenColumnEdgeDrag, .keySpringThenSplitDrag:
            #expect(PaneResize.press("a", .right, model: rig.model, view: rig.root), "the key press changed nothing")
            for tick in 1...3 { rig.frame(edges, "key spring frame \(tick)") }
            try #require(try rig.screen.hasMotion, "the key press did not start a spring")
            // While column A's edge still springs, a drag on the edge or divider beside it.
            // Column B's edge is b2's right edge; the split's divider is b1's.
            let (kind, dragged): (DividerHandleView.Kind, PaneID) = overlap == .keySpringThenColumnEdgeDrag
                ? (.columnEdge("B"), "b2") : (.split("x"), "b1")
            try rig.drag(kind, dragged: dragged, moves: 10, step: -3, edges: edges)
            rig.land(edges, "landing")
        case .releaseSpringThenKeyPress:
            // A Shift drag of the split from 0.3 toward 0.44: its release lands on the half, on a spring.
            let room = try #require(try rig.screen.geometry.dividers.first { $0.id == "x" }).container.width
            try rig.drag(.split("x"), dragged: "b1", moves: 4, step: (room * 0.035).rounded(), flags: .shift, edges: edges)
            for tick in 1...2 { rig.frame(edges, "release spring frame \(tick)") }
            try #require(try rig.screen.hasMotion, "the Shift release did not spring")
            // While the release springs, a key press grows column A: every pane after it moves.
            #expect(PaneResize.press("a", .right, model: rig.model, view: rig.root), "the key press changed nothing")
            rig.land(edges, "key spring")
        }

        print("SHARED-EDGE case=\(overlap.rawValue) ticks=\(rig.ticks) misses=\(rig.misses.count)")
        #expect(rig.misses.isEmpty, """
            \(overlap.rawValue): \(rig.misses.count) checks off in \(rig.ticks) frames (first 12):
            \(rig.misses.prefix(12).joined(separator: "\n"))
            """)
    }
}
