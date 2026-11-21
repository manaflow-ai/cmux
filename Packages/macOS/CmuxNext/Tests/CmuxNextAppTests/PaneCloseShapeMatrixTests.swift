import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// A close is one commit: its end is known when it starts, so every frame shows one whole layout, the one before the
/// close or the one after it, and never a pane between the two. A close in two parts (first a shift, then a growth) is
/// what this matrix was made against; one commit has no parts.
///
/// The matrix closes each pane of nested H/V shapes (2 to 4 levels; left | right[top[A | B] / bottom] among them, the
/// same right side as a column beside another column, and a strip of three columns) through the key's close
/// (`showPaneClose`, which Cmd-W on a pane's last tab and the close-pane action both reach) and through the last-tab
/// path, whose daemon echoes (the emptied pane, then the tree without it) come after the close showed. For every pane
/// that stays, from its host and its terminal's surface in the window:
/// - (a) a close that resizes a pane waits for the next frame tick (`ScreenContentView+SnapFrame`): in its own turn every
///   pane and surface shows where it showed before the close, and the closed pane's host still shows in its place;
/// - (b) a close that resizes no pane (a column of a strip whose other columns keep their widths) shows in its own
///   turn: every pane is where it stays, and the closed pane's host is hidden;
/// - (c) one frame tick shows the new layout, whole: every pane and surface is where it stays, the closed pane's host is
///   hidden, and the tick asks for no other frame;
/// - (d) nothing moves after that tick: not at the next tick, not when the closed pane's host is torn down after the
///   commit, and not at the daemon's echoes.
/// A close waits longer than one tick only for a `PaneCommitSurface` in a pane it resizes
/// (`ScreenContentView.commitBound`); no content of this matrix is one. Chromium pages are not in this matrix: no app
/// test can run one.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseShapeMatrixTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    struct Shape {
        let name: String
        let layout: ScreenLayout
        let closes: [PaneID]
    }

    enum Path: String, CaseIterable {
        /// The key's turn only: `showPaneClose` (Cmd-W on a pane's last tab, the close-pane action, the undo toast's reclose).
        case close
        /// The last tab's close as the daemon answers it: the key's close, then, after the close showed, the echo of the
        /// emptied pane (still in the tree) and the echo of the tree without it.
        case lastTab = "last tab"
    }

    static func h(_ id: String, _ a: SplitNode, _ b: SplitNode, ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: .horizontal, ratio: ratio, a: a, b: b)
    }

    static func v(_ id: String, _ a: SplitNode, _ b: SplitNode, ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: .vertical, ratio: ratio, a: a, b: b)
    }

    static func leaf(_ id: String) -> SplitNode { .leaf(PaneID(id)) }

    /// The right side of the first shape: top[A | B] / bottom.
    static let nestedRight = v("right", h("top", leaf("A"), leaf("B")), leaf("bottom"))

    static let shapes: [Shape] = [
        // The first shape: left | right[top[A | B] / bottom].
        Shape(name: "left | right[top[A|B] / bottom]", layout: PaneGroundCoversPaneTests.column(h("s", leaf("left"), nestedRight)),
              closes: ["left", "A", "B", "bottom"]),
        // Its mirror: the closing pane is on the right.
        Shape(name: "[top[A|B] / bottom] | right", layout: PaneGroundCoversPaneTests.column(h("s", nestedRight, leaf("right"))),
              closes: ["right", "A", "B"]),
        // A row of three: first, middle, last.
        Shape(name: "p1 | p2 | p3", layout: PaneGroundCoversPaneTests.column(h("r1", leaf("p1"), h("r2", leaf("p2"), leaf("p3")), ratio: 1.0 / 3)),
              closes: ["p1", "p2", "p3"]),
        // A stack of three.
        Shape(name: "p1 / p2 / p3", layout: PaneGroundCoversPaneTests.column(v("r1", leaf("p1"), v("r2", leaf("p2"), leaf("p3")), ratio: 1.0 / 3)),
              closes: ["p1", "p2", "p3"]),
        // Four levels, alternating: p1 | (p2 / (p3 | (p4 / p5))).
        Shape(name: "p1 | (p2 / (p3 | (p4 / p5)))",
              layout: PaneGroundCoversPaneTests.column(h("d1", leaf("p1"), v("d2", leaf("p2"), h("d3", leaf("p3"), v("d4", leaf("p4"), leaf("p5")))))),
              closes: ["p1", "p3", "p5"]),
        // A vertical root: top / (A | (C / D)).
        Shape(name: "top / (A | (C / D))", layout: PaneGroundCoversPaneTests.column(v("t", leaf("top"), h("b", leaf("A"), v("cd", leaf("C"), leaf("D"))))),
              closes: ["top", "A", "D"]),
        // The first shape's left and right as two columns of the strip.
        Shape(name: "columns: left || right[top[A|B] / bottom]",
              layout: .columns([LayoutColumn(id: "c0", width: 0.5, root: leaf("left")), LayoutColumn(id: "c1", width: 0.5, root: nestedRight)]),
              closes: ["left", "A"]),
        // A strip of three columns of a third. The columns that stay keep their widths (the rig's model does not follow
        // the design settings, so `layout.newColumnWidth` is matchCurrent): a column that closes resizes no pane, and its
        // close shows in its own turn (b). Not the last column: its close moves no pane that stays.
        Shape(name: "columns: p1 || p2 || p3",
              layout: .columns([LayoutColumn(id: "c0", width: 1.0 / 3, root: leaf("p1")), LayoutColumn(id: "c1", width: 1.0 / 3, root: leaf("p2")),
                                LayoutColumn(id: "c2", width: 1.0 / 3, root: leaf("p3"))]),
              closes: ["p1", "p2"]),
    ]

    /// The most two shown rects differ and are still one place: a hundredth of a point. A pane's edges are on the pixel
    /// grid, so a pane that moved or changed size did so by a third of a point or more.
    static let slack: CGFloat = 0.01

    /// Every close of every shape, through both paths, is one commit ((a) to (d) above). The matrix holds both kinds of
    /// close: one that waits for its frame tick, and one that shows in its own turn.
    @Test func everyCloseOfEveryShapeShowsWholeInOneFrame() throws {
        var failures: [String] = []
        var cases = 0, waited = 0, inOwnTurn = 0
        for shape in Self.shapes {
            for pane in shape.closes {
                for path in Path.allCases {
                    cases += 1
                    let result = try Self.run(shape, closing: pane, path: path)
                    if result.waited { waited += 1 } else { inOwnTurn += 1 }
                    failures += result.failures.map { "\(shape.name), close \(pane) (\(path.rawValue)): \($0)" }
                }
            }
        }
        for failure in failures.prefix(40) { print("close-matrix: \(failure)") }
        #expect(failures.isEmpty, "\(failures.count) breaks of the one commit over \(cases) closes: \(failures.prefix(6))")
        #expect(waited > 0 && inOwnTurn > 0,
                "the matrix does not hold both kinds of close: \(waited) waited for their frame tick, \(inOwnTurn) showed in their own turn")
    }

    // MARK: - One close

    /// Where a pane and its terminal show at one moment, in window points.
    struct Sample {
        var pane: CGRect
        var surface: CGRect?
    }

    /// Closes `pane` in `shape` through `path`. Returns whether the close waited for its frame tick (it changes the
    /// size of a pane that stays) and every break of the one commit.
    static func run(_ shape: Shape, closing pane: PaneID, path: Path) throws -> (waited: Bool, failures: [String]) {
        let focused = shape.layout.panes.first { $0 != pane } ?? pane
        let rig = Rig(shape.layout, focused: focused)
        defer { rig.close() }
        rig.root.layoutSubtreeIfNeeded()
        let after = try #require(LayoutModel.removingSplitPane(pane, from: shape.layout), "SETUP: \(pane) is the shape's last pane")
        let survivors = after.panes
        let closing = try #require(rig.root.context.hosts[pane], "SETUP: \(pane) has no host")
        let place = closing.frame

        // Before the close, then the close's own turn.
        let start = try sample(survivors, rig)
        _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close in the key's turn")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        let turn = try sample(survivors, rig)
        let showsInTurn = !closing.isHidden && closing.superview != nil
        let placeInTurn = closing.frame

        // One frame tick.
        let tickAsksForMore = rig.frame()
        let tick = try sample(survivors, rig)
        let showsAfterTick = !closing.isHidden && closing.superview != nil

        // After it: one more tick, the teardown of the closed pane's host after the commit, and the daemon's echoes.
        var later: [(when: String, shown: [PaneID: Sample])] = []
        var asksLater: [String] = []
        if rig.frame() { asksLater.append("the second frame tick") }
        let second = try sample(survivors, rig)
        later.append(("the second frame tick", second))
        rig.commit()
        let committed = try sample(survivors, rig)
        later.append(("the teardown of the closed pane's host", committed))
        let tornDown = closing.superview == nil
        if path == .lastTab {
            for (name, layout) in [("the echo of the emptied pane", shape.layout), ("the echo of the tree without the pane", after)] {
                show(layout, rig)
                if rig.frame() { asksLater.append("the frame tick after \(name)") }
                rig.commit()
                let echoed = try sample(survivors, rig)
                later.append((name, echoed))
            }
        }
        let rest = try sample(survivors, rig)

        var failures: [String] = []
        if differences(start, from: rest).isEmpty { failures.append("SETUP: the close moved no pane that stays: nothing shows it") }
        // The close waits for its frame tick when it changes the size of a pane that stays.
        func size(_ shown: [PaneID: Sample], _ kept: PaneID) -> CGSize { shown[kept]?.pane.size ?? .zero }
        let waits = survivors.contains { kept in
            abs(size(start, kept).width - size(rest, kept).width) > slack || abs(size(start, kept).height - size(rest, kept).height) > slack
        }
        if waits {
            // (a) The old layout, whole, until the frame tick.
            failures += differences(turn, from: start).map { "(a) in the close's turn, before its frame tick, \($0)" }
            if !showsInTurn || !same(placeInTurn, place) {
                let state = showsInTurn ? "shows" : "does not show"
                failures.append("(a) in the close's turn the closed pane's host \(state), at \(placeInTurn) (before the close: \(place))")
            }
        } else {
            // (b) The new layout, whole, in the close's own turn.
            failures += differences(turn, from: rest).map { "(b) in the close's turn \($0)" }
            if showsInTurn { failures.append("(b) the closed pane's host still shows in the close's turn") }
        }
        // (c) One frame tick shows the new layout, whole, and asks for no other frame.
        failures += differences(tick, from: rest).map { "(c) after one frame tick \($0)" }
        if showsAfterTick { failures.append("(c) the closed pane's host still shows after one frame tick") }
        if tickAsksForMore { failures.append("(c) the frame tick that shows the close asks for another frame") }
        // (d) Nothing moves after it.
        for entry in later { failures += differences(entry.shown, from: rest).map { "(d) after \(entry.when) \($0)" } }
        failures += asksLater.map { "(d) \($0) asks for another frame" }
        if !tornDown { failures.append("(d) the closed pane's host is still in the view tree after the commit of the frame that showed the close") }
        return (waits, failures)
    }

    static func show(_ layout: ScreenLayout, _ rig: Rig) {
        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
        rig.root.syncWithModel()
    }

    static func sample(_ panes: [PaneID], _ rig: Rig) throws -> [PaneID: Sample] {
        var samples: [PaneID: Sample] = [:]
        for pane in panes {
            let host = try #require(rig.root.context.hosts[pane], "\(pane) has no host")
            let surface = rig.provider.sessions[pane]?.session.surfaceView
            samples[pane] = Sample(pane: host.convert(host.bounds, to: nil), surface: surface.map { $0.convert($0.bounds, to: nil) })
        }
        return samples
    }

    /// What `shown` has at another place or size than `expected`: each pane's host, and its terminal's surface.
    static func differences(_ shown: [PaneID: Sample], from expected: [PaneID: Sample]) -> [String] {
        var found: [String] = []
        for pane in expected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let want = expected[pane] else { continue }
            guard let now = shown[pane] else {
                found.append("\(pane) has no sample")
                continue
            }
            if !same(now.pane, want.pane) { found.append("\(pane) shows at \(now.pane), not at \(want.pane)") }
            if let surface = now.surface, let wanted = want.surface, !same(surface, wanted) {
                found.append("the terminal surface of \(pane) shows at \(surface), not at \(wanted)")
            }
        }
        return found
    }

    /// Whether `a` and `b` are one place and size (``slack``).
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack && abs(a.width - b.width) <= slack && abs(a.height - b.height) <= slack
    }
}
