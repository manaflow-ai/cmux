import AppKit
import CmuxNextBridge
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S2B: two panes that share an edge show it at the same place in every frame, also when two
/// motions overlap: their gap is the gap at rest, never wider (the shell shows between them) and never narrower (they
/// overlap), and a divider a person drags moves with the pointer, as much as the pointer travels.
///
/// Each pane frame and each divider frame is its own spring (`AnimatedFrame`). They agree only while they all step
/// together from consistent values. Before S2B a drag snapped every frame it retargets to its target
/// (`ScreenContentView.place`, M3) while a frame it does not retarget kept its spring: when a drag started during a key
/// resize's spring, the dragged column's panes jumped to their rest place and the springing column beside them was
/// still on its way.
/// Rule D (the refactor owner, 2026-11-04, from films of a drag during a key spring): a grab holds the dragged edge
/// where the screen draws it, in view space. The pointer alone moves it from there, 1:1, and it holds still with a
/// still pointer. Its anchor (the edge across the pane or span the drag resizes) and the edges before it keep their
/// springs, so that pane's size changes while the anchor lands. The test reads the dragged edge as the screen draws it.
///
/// Three cases on one layout, A | B (split x: b1 | b2) | C, a strip that fits its viewport:
/// - a key press grows column A (its edge springs) and, while it springs, a drag starts on B's column edge;
/// - the same, with the drag on the split divider inside B (toward b2: b1 is 13 pt above its minimum width);
/// - a Shift drag of the split divider lands on a snap (its release springs) and, while that springs, a key press
///   grows column A;
/// - a key press grows column A and, during that spring, an Option drag of the split in B (B grows, C moves);
/// - a key press grows column A and, during that spring, a Shift drag of the split in B, released with speed (its
///   release seeds the spring's velocity).
/// Rule C (an animation is interruptible from its current value): a grab takes over at what is on screen. Four
/// more cases:
/// - a Shift drag of the split lands on a snap and, while that release springs, the divider is grabbed again: the press
///   moves nothing, the pane then changes 1:1 with the pointer from where it showed, and holds still with the pointer;
/// - column A grows on a spring (a preset width) and, while it grows, a drag of A's edge shrinks it past where it
///   shows down to its minimum: no width ever goes below zero, and A changes 1:1 from where it showed;
/// - a Shift release of the split and a new pane under c (a split of c) in the same layout pass while A's growth
///   carries c: the new pane stays in c's column, at c's place and speed across the axis (the release's fling does not
///   take it over);
/// - a click on the divider during a release spring changes nothing (the press's catch is put back);
/// - the same rule along the other axis and on a dock (#35036 review follow-ups): a top-and-bottom split whose divider
///   is grabbed while an equalize moves it, and a right dock whose inner edge is grabbed while the dock grows (the
///   strip's viewport narrows under it, so every strip column springs too);
/// - a whole column slides on a spring (A grows: B and C move as one) while B's edge or its split is dragged: the
///   dragged edge does not slide with its column, it stays where the pointer puts it;
/// - a pane whose anchor moves toward the dragged edge (A's edge springs into B while b1's split is held): the edge
///   stops at the anchor's place plus b1's minimum, never closer; a pointer that moves toward that place faster than
///   the edge springs there, or past it, holds the edge: it never shows behind the pointer (the split, and B's column
///   edge with B near its minimum width); and the pane between the anchor and the edge never shows under its minimum
///   while the anchor still moves (the anchor pushes the edge once the pane reaches its minimum);
/// - in every case the motion stops: within 2 s every pane and divider frame is at rest on its target.
/// The test is the display clock (`driver.isManual`, 120 Hz) and checks every frame tick: the shared pane edges (side
/// by side, and one above the other), the split divider against b1's edge, and that no pane or divider shows a
/// negative size.
@MainActor
@Suite(.closesItsWindows)
struct SharedEdgeDuringSpringTests {
    enum Overlap: String, CaseIterable, Sendable {
        case keySpringThenColumnEdgeDrag, keySpringThenSplitDrag, releaseSpringThenKeyPress
        /// A key spring on column A, then an Option drag of the split in B (B grows and pushes C).
        case keySpringThenPushDrag
        /// A key spring on column A, then a Shift drag of the split in B whose release flings onto a snap: the release
        /// seeds its spring's velocity (`SplitMotion.seed`) while A still springs.
        case keySpringThenFlingRelease
        /// A Shift release of the split springs onto a snap; the divider is grabbed again while it springs.
        case regrabDuringReleaseSpring
        /// Column A grows on a spring; a drag of its edge shrinks it to its minimum while it grows.
        case shrinkDuringGrowth
        /// A Shift release of the split and a split of c land in one layout pass while A's key spring carries c.
        case newPaneAtRelease
        /// A Shift release of the split springs onto a snap; a click on the divider while it springs (a press and a
        /// release, no move) changes nothing: the release's value stays and the spring goes on.
        case clickDuringReleaseSpring
        /// A wide column B whose split equalizes on a spring (b1 grows by far more than a pane's minimum); while b1
        /// grows, B's edge is dragged in to B's minimum. No pane may show a negative width (a move keeps b1's leftover
        /// of its own spring): this press takes the drag from before S2B, which shows none. Green on feat too: a guard
        /// for the rule.
        case shrinkColumnDuringInnerSpring
        /// B split top and bottom (b1 over b2): an equalize springs its divider down; while it moves, the divider is
        /// grabbed and dragged up, then held still.
        case regrabVerticalSplitDuringEqualize
        /// A right dock D grows on a spring (a width change): its inner edge moves left and the strip's viewport
        /// narrows, so every strip column springs too. While D grows, its inner edge is grabbed and dragged on.
        case dockEdgeDragDuringItsGrowth
        /// A grows by width (a key would trade with B), so B and C slide right as one; B's edge is grabbed while they
        /// slide, then held still.
        case columnSlideThenColumnEdgeDrag
        /// The same slide; the split in B is grabbed while B slides, then held still.
        case columnSlideThenSplitDrag
        /// A grows by width so A's edge springs right into B while b1's split, near b1's minimum, is held: the split
        /// stops at A's edge plus b1's minimum, and comes to rest there while still held.
        case anchorPushesSplitToMinimum
        /// The same clamp; before the split reaches the clamp, the pointer moves past it: from that frame on the split is
        /// where the pointer puts it (the clamp's spring is dropped, not carried along).
        case pointerPassesTheClampBeforeItLands
        /// The same clamp; the pointer moves toward it a quarter of the way each frame, faster than the split springs
        /// there: the split never shows behind the pointer (the pointer takes over the part of the spring it passes).
        case pointerChasesTheClamp
        /// The same on B's column edge: A's edge springs into B by more than B has above its minimum width.
        case pointerChasesTheColumnEdgeClamp
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Two panes whose rest frames share an edge, and the gap between them at rest: a vertical edge (`left` | `right`,
    /// side by side) or, `stacked`, a horizontal one (`left` over `right`, in the screen's flipped space).
    struct SharedEdge {
        var left: PaneID
        var right: PaneID
        var rest: CGFloat
        var stacked = false

        var name: String { stacked ? "\(left)/\(right)" : "\(left)|\(right)" }

        /// The gap between the two frames across this edge.
        func gap(_ l: CGRect, _ r: CGRect) -> CGFloat { stacked ? r.minY - l.maxY : r.minX - l.maxX }
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
        /// The split divider frame's near edge less b1's frame's far edge at rest (their springs, not rounded).
        var dividerRest: CGFloat?
        /// A span the checks keep at its minimum or more, as the screen shows it: from `from`'s left edge to `to`'s right
        /// edge (a clamp: the pane or column between the anchor and the held line).
        var minimumWatch: (from: PaneID, to: PaneID, minimum: CGFloat)?
        /// The split in column B whose divider the checks follow, b1 on its first side, and its axis.
        let split: SplitID
        let splitAxis: SplitAxis

        /// A | B (split x: b1 | b2) | C, a strip that fits its viewport.
        convenience init(widths: (a: Double, b: Double, c: Double) = (0.3, 0.4, 0.2), ratio: Double = 0.3) {
            self.init(columns: [
                LayoutColumn(id: "A", width: widths.a, root: .leaf("a")),
                LayoutColumn(id: "B", width: widths.b, root: .split("x", axis: .horizontal, ratio: ratio, a: .leaf("b1"), b: .leaf("b2"))),
                LayoutColumn(id: "C", width: widths.c, root: .leaf("c")),
            ])
        }

        /// A | B (split y: b1 over b2) | C.
        static func verticalSplit() -> Rig {
            Rig(columns: [
                LayoutColumn(id: "A", width: 0.3, root: .leaf("a")),
                LayoutColumn(id: "B", width: 0.4, root: .split("y", axis: .vertical, ratio: 0.3, a: .leaf("b1"), b: .leaf("b2"))),
                LayoutColumn(id: "C", width: 0.2, root: .leaf("c")),
            ], split: "y", splitAxis: .vertical)
        }

        /// A | B (split x: b1 | b2) | C in the strip, and D docked on the right (the strip's viewport leaves it room).
        static func rightDock() -> Rig {
            Rig(columns: [
                LayoutColumn(id: "A", width: 0.3, root: .leaf("a")),
                LayoutColumn(id: "B", width: 0.4, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("b1"), b: .leaf("b2"))),
                LayoutColumn(id: "C", width: 0.2, root: .leaf("c")),
                LayoutColumn(id: "D", width: 0.25, root: .leaf("d"), dock: DockColumn(edge: .right, mode: .docked)),
            ])
        }

        init(columns: [LayoutColumn], split: SplitID = "x", splitAxis: SplitAxis = .horizontal) {
            _ = NSApplication.shared
            self.split = split
            self.splitAxis = splitAxis
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

        /// The pairs of panes that share an edge at rest (side by side, or one above the other), with their rest gaps,
        /// from the host frames shown.
        func sharedEdges() throws -> [SharedEdge] {
            let shown = try screen.layout.panes.compactMap { pane in root.context.hosts[pane].map { (pane, $0.frame) } }
            var edges: [SharedEdge] = []
            for (left, l) in shown {
                for (right, r) in shown where right != left {
                    for stacked in [false, true] {
                        let edge = SharedEdge(left: left, right: right, rest: 0, stacked: stacked), gap = edge.gap(l, r)
                        let overlap = stacked ? min(l.maxX, r.maxX) - max(l.minX, r.minX) : min(l.maxY, r.maxY) - max(l.minY, r.minY)
                        if gap >= 0, gap <= 24, overlap > 1 { edges.append(SharedEdge(left: left, right: right, rest: gap, stacked: stacked)) }
                    }
                }
            }
            return edges
        }

        /// Half a device pixel and float slack: the farthest a divider that follows the pointer may show from it.
        var halfPixel: CGFloat { get throws { 0.5 / max(try screen.scale, 1) + 0.01 } }

        /// The split divider frame's near edge less b1's frame's far edge along the split's axis, as their springs show
        /// them now.
        func dividerOffset() -> CGFloat? {
            guard let screen = root.screenViews["s"], let divider = screen.dividerFrames[.split(split)], let b1 = screen.paneFrames["b1"] else {
                return nil
            }
            return splitAxis == .horizontal ? divider.rect.minX - b1.rect.maxX : divider.rect.minY - b1.rect.maxY
        }

        /// Records each shared edge whose gap is not its rest gap, as the screen shows it now; the split divider's
        /// gap to b1's edge the same way; and every pane or divider frame that shows a negative size.
        func check(_ edges: [SharedEdge], _ label: String) {
            for edge in edges {
                guard let l = root.context.hosts[edge.left]?.frame, let r = root.context.hosts[edge.right]?.frame else { continue }
                let gap = edge.gap(l, r)
                if abs(gap - edge.rest) > Self.edgeSlack {
                    misses.append("\(label): \(edge.name) gap \(Self.pt(gap)) pt, at rest \(Self.pt(edge.rest)) pt")
                }
            }
            if let rest = dividerRest, let offset = dividerOffset(), abs(offset - rest) > Self.edgeSlack {
                misses.append("\(label): the split divider shows \(Self.pt(offset)) pt from b1's edge, at rest \(Self.pt(rest)) pt")
            }
            if let watch = minimumWatch, let from = root.context.hosts[watch.from]?.frame, let to = root.context.hosts[watch.to]?.frame,
               to.maxX - from.minX < watch.minimum - Self.edgeSlack {
                misses.append("\(label): \(watch.from)...\(watch.to) shows \(Self.pt(to.maxX - from.minX)) pt wide, under its minimum \(Self.pt(watch.minimum)) pt")
            }
            guard let screen = root.screenViews["s"] else { return }
            // The springs' own values: `CGRect.width` is never negative (it reads the standardized rect).
            for (pane, frame) in screen.paneFrames where frame.width.value < 0 || frame.height.value < 0 {
                misses.append("\(label): \(pane) shows a negative size \(Self.pt(frame.width.value)) x \(Self.pt(frame.height.value))")
            }
            for (kind, frame) in screen.dividerFrames where frame.width.value < 0 || frame.height.value < 0 {
                misses.append("\(label): divider \(kind) shows a negative size \(Self.pt(frame.width.value)) x \(Self.pt(frame.height.value))")
            }
        }

        /// One display frame, then the check.
        func frame(_ edges: [SharedEdge], _ label: String) {
            _ = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            ticks += 1
            check(edges, label)
        }

        /// The edge `side` of `pane` as the screen shows it (its host's frame, in the screen's space).
        func edge(_ pane: PaneID, _ side: KeyPath<CGRect, CGFloat>) throws -> CGFloat {
            try #require(root.context.hosts[pane], "no host for \(pane)").frame[keyPath: side]
        }

        /// The edge `side` of `pane` where the screen will draw it at rest (its spring's target, placed and on the pixel
        /// grid as `ScreenContentView.applyPresentation` places hosts).
        func restEdge(_ pane: PaneID, _ side: KeyPath<CGRect, CGFloat>) throws -> CGFloat {
            let screen = try screen, frame = try #require(screen.paneFrames[pane], "no frame for \(pane)")
            return screen.displayedRect(frame.targetRect, pane: pane).pixelEdges(screen.scale)[keyPath: side]
        }

        /// The pointer `window` (window coordinates) along `axis` in the screen's space (flipped: y grows down).
        func along(_ axis: SplitAxis, _ window: CGPoint) throws -> CGFloat {
            let point = try screen.convert(window, from: nil)
            return axis == .horizontal ? point.x : point.y
        }

        /// Starts column A's key spring (a press grows it) and checks its frames.
        func keySpring(_ edges: [SharedEdge]) throws {
            #expect(PaneResize.press("a", .right, model: model, view: root), "the key press changed nothing")
            for tick in 1...3 { frame(edges, "key spring frame \(tick)") }
            try #require(try screen.hasMotion, "the key press did not start a spring")
        }

        static func pt(_ value: CGFloat) -> String { String(format: "%.2f", value) }

        /// Some component of `frame` still has a velocity.
        static func moves(_ frame: AnimatedFrame) -> Bool {
            frame.x.velocity != 0 || frame.y.velocity != 0 || frame.width.velocity != 0 || frame.height.velocity != 0
        }

        /// How far two values of one shared edge may differ: under half a point (float rounding and pixel edges, never
        /// a gap or an overlap anyone sees). Exact float equality is not the rule.
        static let edgeSlack: CGFloat = 0.5
    }

    @Test(arguments: Overlap.allCases)
    func panesThatShareAnEdgeShowItAtOnePlaceInEveryFrame(_ overlap: Overlap) throws {
        let rig = switch overlap {
        case .shrinkColumnDuringInnerSpring: Rig(widths: (0.15, 0.7, 0.15), ratio: 0.15)
        case .regrabVerticalSplitDuringEqualize: Rig.verticalSplit()
        case .dockEdgeDragDuringItsGrowth: Rig.rightDock()
        // b1 with room on both sides where its split is dragged while B moves (the default rig's b1 is 13 pt above its
        // minimum: the anchor's motion would clamp it, which anchorPushesSplitToMinimum tests on purpose).
        case .columnSlideThenSplitDrag, .keySpringThenSplitDrag, .keySpringThenPushDrag, .keySpringThenFlingRelease, .newPaneAtRelease:
            Rig(ratio: 0.5)
        // B about 40 pt above its minimum width (b1 and b2 about 20 pt above theirs): A's growth clamps B's edge.
        case .pointerChasesTheColumnEdgeClamp: Rig(widths: (0.3, 0.25, 0.2), ratio: 0.5)
        default: Rig()
        }
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        // a|b1 and b2|c (column gaps) and b1|b2 (the split's divider gap); top and bottom, a and c beside both of B's
        // panes and b1/b2 one above the other. The strip does not reach the dock (it fills 90 % of its viewport).
        let expected: Set<String> = overlap == .regrabVerticalSplitDuringEqualize
            ? ["a|b1", "a|b2", "b1|c", "b2|c", "b1/b2"] : ["a|b1", "b1|b2", "b2|c"]
        try #require(Set(edges.map(\.name)) == expected, "shared edges at rest: \(edges.map(\.name).sorted())")
        let dividerRest: CGFloat = try #require(rig.dividerOffset(), "no split divider")
        rig.dividerRest = dividerRest

        switch overlap {
        case .keySpringThenColumnEdgeDrag, .keySpringThenSplitDrag:
            try rig.keySpring(edges)
            // While column A's edge still springs, a drag on the edge or divider beside it.
            // Column B's edge is b2's right edge; the split's divider is b1's.
            // The column edge goes left (B narrows); the split goes right, where b1 has room (it is 13 pt above its
            // minimum width, so a left drag would stop at the minimum).
            let (kind, dragged, step): (DividerHandleView.Kind, PaneID, CGFloat) = overlap == .keySpringThenColumnEdgeDrag
                ? (.columnEdge("B"), "b2", -3) : (.split("x"), "b1", 3)
            try rig.drag(kind, dragged: dragged, moves: 10, step: step, edges: edges)
            rig.land(edges, "landing")
        case .keySpringThenPushDrag:
            try rig.keySpring(edges)
            // Option: the split's left side keeps its width and B grows, pushing C (resize-modifiers.md).
            try rig.drag(.split("x"), dragged: "b1", moves: 8, step: 4, flags: .option, edges: edges)
            rig.land(edges, "landing")
        case .keySpringThenFlingRelease:
            try rig.keySpring(edges)
            // A Shift drag of the split toward its half, released at 600 pt/s: its release lands on the snap and seeds
            // the release spring's velocity while A still springs.
            let room = try #require(try rig.screen.geometry.dividers.first { $0.id == "x" }).container.width
            try rig.drag(.split("x"), dragged: "b1", moves: 4, step: (room * 0.035).rounded(), flags: .shift, releaseSpeed: 600,
                         edges: edges)
            // The release seeded its fling: the divider starts toward the snap with speed.
            let divider = try #require(try rig.screen.dividerFrames[.split("x")])
            #expect(divider.x.velocity != 0, "the release did not seed the divider's spring")
            rig.land(edges, "release spring")
        case .regrabDuringReleaseSpring:
            // A Shift release onto the half, then two frames of its spring, then the divider grabbed again where it
            // shows and dragged on: the press moves nothing, the drag goes 1:1 from there, and a still pointer holds it.
            let room = try #require(try rig.screen.geometry.dividers.first { $0.id == "x" }).container.width
            try rig.drag(.split("x"), dragged: "b1", moves: 4, step: (room * 0.035).rounded(), flags: .shift, edges: edges)
            for tick in 1...2 { rig.frame(edges, "release spring frame \(tick)") }
            let divider = try #require(try rig.screen.dividerFrames[.split("x")])
            try #require(abs(divider.x.value - divider.x.target) > 8, "the release spring is nearly done: \(divider.x.value) -> \(divider.x.target)")
            try rig.drag(.split("x"), dragged: "b1", moves: 6, step: 3, still: 6, edges: edges)
            rig.land(edges, "landing")
        case .shrinkDuringGrowth:
            // Column A to half the strip on a spring (a preset width), then, while it grows, its edge dragged left past
            // where it shows, down to A's minimum width and on.
            rig.model.setColumnWidth("A", width: 0.5, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            for tick in 1...2 { rig.frame(edges, "growth frame \(tick)") }
            let a = try #require(try rig.screen.paneFrames["a"])
            try #require(a.targetRect.width - a.rect.width > 150, "A is nearly grown: \(a.rect.width) -> \(a.targetRect.width)")
            let minimum = rig.root.context.style.minimumPaneSize.width
            try rig.drag(.columnEdge("A"), dragged: "a", anchor: "a", moves: 16, step: -40, floor: minimum, edges: edges)
            rig.land(edges, "landing")
        case .shrinkColumnDuringInnerSpring:
            // Equalize the split (an explicit equalize springs): b1 grows from its minimum to half of B.
            rig.model.equalizeSplit("x")
            rig.root.syncWithModel()
            rig.frame(edges, "equalize frame 1")
            let b1 = try #require(try rig.screen.paneFrames["b1"])
            let minimum = rig.root.context.style.minimumPaneSize.width
            try #require(b1.targetRect.width - b1.rect.width > minimum + 20,
                         "b1 is nearly grown: \(b1.rect.width) -> \(b1.targetRect.width)")
            let column = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "B" })
            // B's right edge in to B's minimum width in one move, while b1 still grows (a slower drag lets its spring
            // settle first): b2's right edge from b1's left edge (B's left edge).
            try rig.drag(.columnEdge("B"), dragged: "b2", moves: 1, step: -900, floor: column.minimumSize(style: rig.root.context.style).width,
                         edges: edges)
            rig.land(edges, "landing")
        case .regrabVerticalSplitDuringEqualize:
            // b1 holds 0.3 of B's height; an equalize (it springs) takes it toward half. While the divider moves down,
            // it is grabbed where it shows and dragged up (b1 shrinks 1:1), then held still.
            rig.model.equalizeSplit("y")
            rig.root.syncWithModel()
            for tick in 1...2 { rig.frame(edges, "equalize frame \(tick)") }
            let divider = try #require(try rig.screen.dividerFrames[.split("y")])
            try #require(abs(divider.y.value - divider.y.target) > 8, "the equalize spring is nearly done: \(divider.y.value) -> \(divider.y.target)")
            try rig.drag(.split("y"), dragged: "b1", anchor: "b1", axis: .vertical, edge: \.maxY, anchorEdge: \.minY, moves: 6, step: 3,
                         still: 6, edges: edges)
            rig.land(edges, "landing")
        case .dockEdgeDragDuringItsGrowth:
            // D from a quarter of the view to 35 % (a width change springs): its inner edge moves left, and the strip's
            // viewport, so every strip column, narrows with it. While D grows, its inner edge is grabbed where it shows
            // and dragged on to the left (D grows 1:1), then held still. Its outer edge (the view's) is the anchor.
            rig.model.setColumnWidth("D", width: 0.35, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            for tick in 1...2 { rig.frame(edges, "growth frame \(tick)") }
            let d = try #require(try rig.screen.paneFrames["d"])
            try #require(abs(d.rect.minX - d.targetRect.minX) > 8, "D is nearly grown: \(d.rect.minX) -> \(d.targetRect.minX)")
            try #require(try rig.screen.paneFrames["c"].map { abs($0.rect.maxX - $0.targetRect.maxX) > 4 } == true,
                         "D's growth does not move the strip")
            try rig.drag(.columnEdge("D"), dragged: "d", anchor: "d", edge: \.minX, anchorEdge: \.maxX, moves: 6, step: -3, still: 6,
                         edges: edges)
            rig.land(edges, "landing")
        case .columnSlideThenColumnEdgeDrag, .columnSlideThenSplitDrag:
            // A from 0.3 to 0.35 of the strip (a width change springs): B and C slide right as one. While they slide, B's
            // edge (or the split in B) is grabbed where it shows, dragged left, then held still: it does not slide on.
            rig.model.setColumnWidth("A", width: 0.35, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            for tick in 1...2 { rig.frame(edges, "slide frame \(tick)") }
            let b1 = try #require(try rig.screen.paneFrames["b1"])
            try #require(b1.targetRect.minX - b1.rect.minX > 40, "B nearly slid: \(b1.rect.minX) -> \(b1.targetRect.minX)")
            let (kind, dragged): (DividerHandleView.Kind, PaneID) = overlap == .columnSlideThenColumnEdgeDrag
                ? (.columnEdge("B"), "b2") : (.split("x"), "b1")
            try rig.drag(kind, dragged: dragged, moves: 6, step: -3, still: 12, edges: edges)
            rig.land(edges, "landing")
        case .anchorPushesSplitToMinimum:
            // A grows by 0.07 of the strip on a spring, so A's edge (b1's anchor) moves into B by more than b1 has above
            // its minimum. The split, grabbed during that spring and held still, stops at A's edge plus b1's minimum.
            let minimum = rig.root.context.style.minimumPaneSize.width
            let b1 = try #require(try rig.screen.paneFrames["b1"]).targetRect.width
            try #require(b1 > minimum + 10 && b1 < minimum + 60, "b1 is \(b1) pt, its minimum \(minimum) pt")
            let a = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "A" }).width
            rig.model.setColumnWidth("A", width: a + 0.07, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            rig.frame(edges, "growth frame 1")
            rig.minimumWatch = ("b1", "b1", minimum)
            // Held still until the clamp's spring is done: the split rests at A's rest edge plus b1's minimum.
            try rig.drag(.split("x"), dragged: "b1", moves: 1, step: 1, still: 120, floor: minimum, edges: edges) { view, pointer in
                let shown = try rig.edge("b1", \.maxX), clamp = try rig.restEdge("b1", \.minX) + minimum, tolerance = try rig.halfPixel
                #expect(abs(shown - clamp) <= tolerance, "held still, the split rests at \(Rig.pt(shown)) pt, the clamp is \(Rig.pt(clamp)) pt")
                view.mouseUp(with: rig.event(.leftMouseUp, pointer))
                rig.root.syncWithModel()
                rig.check(edges, "release")
            }
            rig.land(edges, "landing")
        case .pointerPassesTheClampBeforeItLands:
            // The clamp as above; one frame after the press, the pointer moves 30 pt past the clamp in one step, while
            // the split still springs toward it. From then on the split shows where the pointer puts it.
            let minimum = rig.root.context.style.minimumPaneSize.width
            let a = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "A" }).width
            rig.model.setColumnWidth("A", width: a + 0.07, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            rig.frame(edges, "growth frame 1")
            let drawn = try rig.edge("b1", \.maxX), clamp = try rig.restEdge("b1", \.minX) + minimum
            try #require(clamp - drawn > 40, "the split is \(Rig.pt(clamp - drawn)) pt from the clamp: no clamp to pass")
            rig.minimumWatch = ("b1", "b1", minimum)
            try rig.drag(.split("x"), dragged: "b1", moves: 1, step: (clamp - drawn + 30).rounded(), still: 12, floor: minimum, edges: edges)
            rig.land(edges, "landing")
        case .pointerChasesTheClamp, .pointerChasesTheColumnEdgeClamp:
            // The clamp as above (on B's edge: B's minimum width from B's rest place); the pointer moves toward it a
            // quarter of the way each frame for three frames, then holds still while the line goes on to the clamp.
            let style = rig.root.context.style, onEdge = overlap == .pointerChasesTheColumnEdgeClamp
            let column = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "B" })
            let floor = onEdge ? column.minimumSize(style: style).width : style.minimumPaneSize.width
            let (kind, dragged): (DividerHandleView.Kind, PaneID) = onEdge ? (.columnEdge("B"), "b2") : (.split("x"), "b1")
            let a = try #require(rig.model.screens.first?.layout.columns.first { $0.id == "A" }).width
            rig.model.setColumnWidth("A", width: a + 0.07, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            rig.frame(edges, "growth frame 1")
            let drawn = try rig.edge(dragged, \.maxX), clamp = try rig.restEdge("b1", \.minX) + floor
            try #require(clamp - drawn > 40, "the line is \(Rig.pt(clamp - drawn)) pt from the clamp: no clamp to chase")
            rig.minimumWatch = ("b1", dragged, floor)
            try rig.drag(kind, dragged: dragged, moves: 3, step: ((clamp - drawn) / 4).rounded(), still: 12, floor: floor, edges: edges)
            rig.land(edges, "landing")
        case .clickDuringReleaseSpring:
            let room = try #require(try rig.screen.geometry.dividers.first { $0.id == "x" }).container.width
            try rig.drag(.split("x"), dragged: "b1", moves: 4, step: (room * 0.035).rounded(), flags: .shift, edges: edges)
            for tick in 1...2 { rig.frame(edges, "release spring frame \(tick)") }
            let landing = try #require(rig.model.screens.first?.layout.ratio(of: "x"))
            let divider = try #require(try rig.screen.dividerFrames[.split("x")])
            try #require(abs(divider.x.value - divider.x.target) > 8, "the release spring is nearly done")
            let view = try rig.handle(.split("x")), press = try rig.center(.split("x"))
            let shownBefore = try rig.shownFrames()
            view.mouseDown(with: rig.event(.leftMouseDown, press))
            view.mouseUp(with: rig.event(.leftMouseUp, press))
            rig.root.syncWithModel()
            try rig.expectUnmoved(shownBefore, "the click")
            #expect(rig.model.screens.first?.layout.ratio(of: "x") == landing, "the click changed the split's ratio")
            rig.land(edges, "release spring")
            let ratio = try #require(rig.model.screens.first?.layout.ratio(of: "x"))
            #expect(ratio == landing, "the split landed at \(ratio), its release put it at \(landing)")
        case .newPaneAtRelease:
            // Column A grows (a width change, not a key press: a key press trades width with B and C stays): B and C
            // slide on its spring. A Shift drag of the split, and in its release's turn a split of c (c2 under c):
            // one layout pass makes the release and the new pane.
            rig.model.setColumnWidth("A", width: 0.37, transaction: .make(), phase: .ended)
            rig.root.syncWithModel()
            for tick in 1...3 { rig.frame(edges, "growth frame \(tick)") }
            let room = try #require(try rig.screen.geometry.dividers.first { $0.id == "x" }).container.width
            try rig.drag(.split("x"), dragged: "b1", moves: 4, step: (room * 0.035).rounded(), flags: .shift, releaseSpeed: 600,
                         edges: edges) { view, pointer in
                view.mouseUp(with: rig.event(.leftMouseUp, pointer, .shift))
                var columns = try #require(rig.model.screens.first?.layout.columns)
                let c = try #require(columns.firstIndex { $0.id == "C" })
                columns[c].root = .split("y", axis: .vertical, ratio: 0.5, a: .leaf("c"), b: .leaf("c2"))
                _ = rig.model.showSplitSizing(rig.model.splitSizingChanges(splitting: "c", axis: .vertical))
                rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
                rig.root.syncWithModel()
                rig.check(edges, "release")
            }
            let screen = try rig.screen
            let c = try #require(screen.paneFrames["c"]), c2 = try #require(screen.paneFrames["c2"], "the split of c made no c2")
            #expect(c.x.velocity != 0, "A's growth no longer carries c")
            // The new pane rides c across the axis: the release's fling does not give it a speed of its own.
            #expect(abs(c2.x.velocity - c.x.velocity) < 0.5 && abs(c2.width.velocity - c.width.velocity) < 0.5,
                    "c2 moves at x \(c2.x.velocity), width \(c2.width.velocity) pt/s; c at \(c.x.velocity), \(c.width.velocity)")
            var frames = 0
            repeat {
                let upper = try #require(screen.paneFrames["c"]), lower = try #require(screen.paneFrames["c2"])
                if abs(upper.rect.minX - lower.rect.minX) > Rig.edgeSlack || abs(upper.rect.maxX - lower.rect.maxX) > Rig.edgeSlack {
                    rig.misses.append("arrival frame \(frames): c2 shows at x \(Rig.pt(lower.rect.minX))...\(Rig.pt(lower.rect.maxX)), c at \(Rig.pt(upper.rect.minX))...\(Rig.pt(upper.rect.maxX))")
                }
                frames += 1
                rig.frame(edges, "arrival frame \(frames)")
            } while frames < 30
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
