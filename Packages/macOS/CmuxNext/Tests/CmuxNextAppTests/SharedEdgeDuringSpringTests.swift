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
/// together from consistent values. A drag snaps every frame it retargets to its target (`ScreenContentView.place`,
/// M3) while a frame it does not retarget keeps its spring: when a drag starts during a key resize's spring, the
/// dragged column's panes jump to their rest place and the springing column beside them is still on its way. A drag
/// The drag measures the pointer against the rest layout (`DividerDrag.start`): a press changes no size, and the
/// pointer's travel changes the dragged pane's size 1:1. A divider pressed while its column still slides on a spring
/// cannot also stay under the pointer: the column moves under it, so the pane would change by the column's travel
/// (a press alone would resize it). The dragged edge rides its column's spring and moves with the pointer in the
/// column's frame: the test reads it from column B's left edge (b1's), which only the key spring moves.
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
/// - in every case the motion stops: within 2 s every pane and divider frame is at rest on its target.
/// The test is the display clock (`driver.isManual`, 120 Hz) and checks every frame tick: the shared pane edges, the
/// split divider against b1's edge, and that no pane or divider shows a negative size.
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
        /// The split divider frame's left edge less b1's frame's right edge at rest (their springs, not rounded).
        var dividerRest: CGFloat?

        init(widths: (a: Double, b: Double, c: Double) = (0.3, 0.4, 0.2), ratio: Double = 0.3) {
            _ = NSApplication.shared
            let columns = [
                LayoutColumn(id: "A", width: widths.a, root: .leaf("a")),
                LayoutColumn(id: "B", width: widths.b, root: .split("x", axis: .horizontal, ratio: ratio, a: .leaf("b1"), b: .leaf("b2"))),
                LayoutColumn(id: "C", width: widths.c, root: .leaf("c")),
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

        /// The split divider frame's left edge less b1's frame's right edge, as their springs show them now.
        func dividerOffset() -> CGFloat? {
            guard let screen = root.screenViews["s"], let divider = screen.dividerFrames[.split("x")], let b1 = screen.paneFrames["b1"] else {
                return nil
            }
            return divider.rect.minX - b1.rect.maxX
        }

        /// Records each shared edge whose gap is not its rest gap, as the screen shows it now; the split divider's
        /// gap to b1's edge the same way; and every pane or divider frame that shows a negative size.
        func check(_ edges: [SharedEdge], _ label: String) {
            for edge in edges {
                guard let l = root.context.hosts[edge.left]?.frame, let r = root.context.hosts[edge.right]?.frame else { continue }
                let gap = r.minX - l.maxX
                if abs(gap - edge.rest) > Self.edgeSlack {
                    misses.append("\(label): \(edge.left)|\(edge.right) gap \(Self.pt(gap)) pt, at rest \(Self.pt(edge.rest)) pt")
                }
            }
            if let rest = dividerRest, let offset = dividerOffset(), abs(offset - rest) > Self.edgeSlack {
                misses.append("\(label): the split divider shows \(Self.pt(offset)) pt from b1's edge, at rest \(Self.pt(rest)) pt")
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

        /// The right edge of `pane` as the screen shows it (its host's frame).
        func rightEdge(_ pane: PaneID) throws -> CGFloat {
            try #require(root.context.hosts[pane], "no host for \(pane)").frame.maxX
        }

        /// How far the right edge of `pane` shows from the left edge of `anchor` (the first pane of its column): the
        /// dragged edge in its column's frame, which the column's own slide does not change.
        func span(_ pane: PaneID, from anchor: PaneID) throws -> CGFloat {
            try rightEdge(pane) - (try #require(root.context.hosts[anchor], "no host for \(anchor)").frame.minX)
        }

        /// A drag of `kind`, pressed where its handle shows, `moves` steps of `step` points (whole points: the edge
        /// stays on the pixel grid), one display frame per move, then `still` frames with no event. In every frame it
        /// checks the shared edges, and that the dragged edge (the right edge of `dragged`) shows from the left edge of
        /// `anchor` (its column's first pane) as far as at the press plus the pointer's travel, never under `floor`
        /// (the dragged pane's minimum): the grab takes over where the edge shows, the pane changes 1:1 with the
        /// pointer and holds still with it. The press itself (a frame before the first move) moves nothing. Then the
        /// release (`releaseSpeed`: the pointer's speed at it, pt/s, set as the drag samples it), unless `beforeRelease`
        /// takes it over (it gets the pointer and does the release itself).
        func drag(_ kind: DividerHandleView.Kind, dragged: PaneID, anchor: PaneID = "b1", moves: Int, step: CGFloat,
                  flags: NSEvent.ModifierFlags = [], still: Int = 3, floor: CGFloat = 0, releaseSpeed: CGFloat? = nil,
                  edges: [SharedEdge], release: ((DividerHandleView, CGPoint) throws -> Void)? = nil) throws {
            let view = try handle(kind)
            let press = try center(kind)
            let tolerance = try halfPixel
            let start = try span(dragged, from: anchor)
            func expect(_ want: CGFloat, _ label: String) throws {
                let shown = try span(dragged, from: anchor), want = max(want, floor)
                if abs(shown - want) > tolerance {
                    misses.append("\(label): the dragged edge shows \(Self.pt(shown)) pt from \(anchor)'s left edge, the pointer put it at \(Self.pt(want)) pt")
                }
            }
            let shownBefore = try shownFrames()
            view.mouseDown(with: event(.leftMouseDown, press, flags))
            try expectUnmoved(shownBefore, "the press")
            frame(edges, "press frame")
            try expect(start, "press frame")
            var pointer = press
            for move in 1...moves {
                pointer.x += step
                view.mouseDragged(with: event(.leftMouseDragged, pointer, flags))
                frame(edges, "drag frame \(move)")
                try expect(start + CGFloat(move) * step, "drag frame \(move)")
            }
            for tick in 0..<still {
                frame(edges, "still frame \(tick + 1)")
                try expect(start + CGFloat(moves) * step, "still frame \(tick + 1)")
            }
            if let releaseSpeed {
                // The speed is set, not timed: no test sleeps (as DividerDragFollowsPointerTests does).
                try screen.activeDrag?.velocity = releaseSpeed
                try screen.activeDrag?.pointer?.time = CACurrentMediaTime()
            }
            if let release { return try release(view, pointer) }
            view.mouseUp(with: event(.leftMouseUp, pointer, flags))
            root.syncWithModel()
            check(edges, "release")
        }

        /// Every pane and divider frame as it shows now (their springs' values).
        func shownFrames() throws -> [String: CGRect] {
            let screen = try screen
            var shown: [String: CGRect] = [:]
            for (pane, frame) in screen.paneFrames { shown["pane \(pane)"] = frame.rect }
            for (kind, frame) in screen.dividerFrames { shown["divider \(kind)"] = frame.rect }
            return shown
        }

        /// Records every frame that shows elsewhere than in `before` (a press, a click: nothing may move on screen).
        func expectUnmoved(_ before: [String: CGRect], _ label: String) throws {
            for (key, now) in try shownFrames() {
                guard let was = before[key] else { continue }
                if abs(now.minX - was.minX) > 0.001 || abs(now.maxX - was.maxX) > 0.001 || abs(now.minY - was.minY) > 0.001
                    || abs(now.maxY - was.maxY) > 0.001 {
                    misses.append("\(label) moved \(key): \(was) -> \(now)")
                }
            }
        }

        /// Display frames until nothing moves (at most 2 s of them), each checked; then the motion must have stopped:
        /// every pane and divider frame at rest on its target.
        func land(_ edges: [SharedEdge], _ label: String) {
            var frames = 0, moving = true
            while frames < 240, moving {
                frames += 1
                moving = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                ticks += 1
                check(edges, "\(label) frame \(frames)")
            }
            guard let screen = root.screenViews["s"] else { return misses.append("\(label): no screen") }
            if moving || screen.hasMotion { misses.append("\(label): still moving after \(frames) frames") }
            for (pane, frame) in screen.paneFrames where frame.rect != frame.targetRect || Self.moves(frame) {
                misses.append("\(label): \(pane) is not at rest on its target (\(frame.rect) -> \(frame.targetRect))")
            }
            for (kind, frame) in screen.dividerFrames where frame.rect != frame.targetRect || Self.moves(frame) {
                misses.append("\(label): divider \(kind) is not at rest on its target (\(frame.rect) -> \(frame.targetRect))")
            }
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
        // The rule under test is on by default (`motion.frameOwner.sharedEdges`); a run with it turned off tests nothing
        // here. Read by its key: the red run of this file is on a base without the switch.
        try #require(TunableStore.shared.override("motion.frameOwner.sharedEdges") != .bool(false), "motion.frameOwner.sharedEdges is off")
        let rig = overlap == .shrinkColumnDuringInnerSpring ? Rig(widths: (0.15, 0.7, 0.15), ratio: 0.15) : Rig()
        defer { rig.window.closeAfterTest() }
        let edges = try rig.sharedEdges()
        // a|b1 and b2|c (column gaps) and b1|b2 (the split's divider gap).
        try #require(edges.count == 3, "shared edges at rest: \(edges.map { "\($0.left)|\($0.right)" })")
        rig.dividerRest = try #require(rig.dividerOffset(), "no split divider")

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
            rig.model.setColumnWidth("A", width: 0.4, transaction: .make(), phase: .ended)
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
