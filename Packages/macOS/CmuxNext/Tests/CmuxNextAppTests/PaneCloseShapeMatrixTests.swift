import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07 (softened): "you have the left part and then the right main part and then the top and bottom part, and
/// then the top part has two, side by side, and then you close the left one or the right one, and then it plays a two-part
/// animation. It, like, first shifts over to the left ... And then after the shift, then it expands. It's not, like,
/// expanding as it goes ... there must be, like, tons of combinations of this kind of thing where we need to just, like, do
/// a fundamental sweep through of it."
///
/// A close is one state transition: every pane it touches goes from where it shows to where it rests on one curve, with no
/// phase after another and nothing moving after the landing. This matrix closes each pane of nested H/V shapes (2 to 4
/// levels, Leo's left | right[top[A | B] / bottom] among them, and the same right side as a column beside another column)
/// through the key's close (`showPaneClose`, which Cmd-W on a pane's last tab and the close-pane action both reach) and
/// through the last-tab path, whose daemon echoes (the emptied pane, then the tree without it) land mid-spring. On every
/// 120 Hz frame of the frame owner, for every pane that moves or resizes:
/// - (a) each of its four edges in the window moves only toward its rest, never past it (edges, not origin and size: each
///   edge lands on the pixel grid on its own, so a size can step a pixel back while both its edges move steadily);
/// - (b) every moving edge of every pane is at the same fraction of its travel (one curve: a shift that runs ahead of a
///   growth, or a second spring after the first, breaks it);
/// - (c) its terminal's held surface never moves away from its rest and never jumps more in a frame than its pane's
///   edge does (the text rides the pane, `TerminalHostView` `surfacePlacement`);
/// - (d) nothing moves after the landing frame (no pop-in after the motion ended).
/// Chromium pages, which no app test can run, are held to the same transition in `CEFPageFrameOwnerTests`.
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
        /// The last tab's close as the daemon answers it: the key's close, then mid-spring the echo of the emptied pane
        /// (still in the tree) and the echo of the tree without it.
        case lastTab = "last tab"
    }

    static func h(_ id: String, _ a: SplitNode, _ b: SplitNode, ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: .horizontal, ratio: ratio, a: a, b: b)
    }

    static func v(_ id: String, _ a: SplitNode, _ b: SplitNode, ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: .vertical, ratio: ratio, a: a, b: b)
    }

    static func leaf(_ id: String) -> SplitNode { .leaf(PaneID(id)) }

    /// Leo's right side: top[A | B] / bottom.
    static let leosRight = v("right", h("top", leaf("A"), leaf("B")), leaf("bottom"))

    static let shapes: [Shape] = [
        // Leo's shape: left | right[top[A | B] / bottom].
        Shape(name: "left | right[top[A|B] / bottom]", layout: PaneGroundCoversPaneTests.column(h("s", leaf("left"), leosRight)),
              closes: ["left", "A", "B", "bottom"]),
        // Its mirror: the closing pane is on the right.
        Shape(name: "[top[A|B] / bottom] | right", layout: PaneGroundCoversPaneTests.column(h("s", leosRight, leaf("right"))),
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
        // Leo's left and right as two columns of the strip.
        Shape(name: "columns: left || right[top[A|B] / bottom]",
              layout: .columns([LayoutColumn(id: "c0", width: 0.5, root: leaf("left")), LayoutColumn(id: "c1", width: 0.5, root: leosRight)]),
              closes: ["left", "A"]),
    ]

    /// Edges that travel less than this are left out of the fraction check (their rounding is most of their travel).
    static let minTravel: CGFloat = 4

    @Test func everyCloseOfEveryShapeMovesEachPaneOnOneCurveToItsRest() throws {
        var failures: [String] = []
        var cases = 0
        for shape in Self.shapes {
            for pane in shape.closes {
                for path in Path.allCases {
                    cases += 1
                    let found = try Self.run(shape, closing: pane, path: path)
                    failures += found.map { "\(shape.name), close \(pane) (\(path.rawValue)): \($0)" }
                }
            }
        }
        for failure in failures.prefix(40) { print("close-matrix: \(failure)") }
        #expect(failures.isEmpty, "\(failures.count) breaks of one motion over \(cases) closes: \(failures.prefix(6))")
    }

    // MARK: - One close

    /// Where a pane and its terminal show in one frame, in window points.
    struct Sample {
        var pane: CGRect
        var surface: CGRect?
    }

    /// Closes `pane` in `shape` through `path` and returns every frame that breaks one motion.
    static func run(_ shape: Shape, closing pane: PaneID, path: Path) throws -> [String] {
        let focused = shape.layout.panes.first { $0 != pane } ?? pane
        let rig = Rig(shape.layout, focused: focused)
        defer { rig.close() }
        rig.root.layoutSubtreeIfNeeded()
        let after = try #require(LayoutModel.removingSplitPane(pane, from: shape.layout), "SETUP: \(pane) is the shape's last pane")
        let survivors = after.panes

        var frames: [[PaneID: Sample]] = [try sample(survivors, rig)]
        _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close in the key's turn")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        frames.append(try sample(survivors, rig))
        var count = 0
        while count < 240, rig.frame() {
            count += 1
            if path == .lastTab, count == 4 { show(shape.layout, rig) }
            if path == .lastTab, count == 8 { show(after, rig) }
            frames.append(try sample(survivors, rig))
        }
        rig.commit()
        try #require(count > 3, "the close did not spring (\(count) frames)")
        rig.root.layoutSubtreeIfNeeded()
        let rest = try sample(survivors, rig)
        // Each edge lands on the window's pixel grid on its own (`pixelEdges`): half a pixel off its exact curve at most,
        // and the reference edge's fraction as much again, so one pixel is the slack of the fraction check.
        let pixel = 1 / max(1, rig.window.backingScaleFactor)
        return check(frames, rest: rest, tolerance: pixel + 0.01)
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

    /// The pane edges the checks read, in the window: leading, trailing, bottom, top.
    static let components: [(String, (CGRect) -> CGFloat)] = [("minX", \.minX), ("maxX", \.maxX), ("minY", \.minY), ("maxY", \.maxY)]

    static func check(_ frames: [[PaneID: Sample]], rest: [PaneID: Sample], tolerance: CGFloat) -> [String] {
        var found: [String] = []
        guard let start = frames.first else { return ["no frames"] }
        let panes = rest.keys.sorted { $0.rawValue < $1.rawValue }
        // (a) and (d): each edge of each pane moves only toward its rest, never past it, and stays put after the landing.
        var trace = MotionTargetTrace()
        for pane in panes {
            for (name, read) in components {
                for frame in frames { if let rect = frame[pane]?.pane { trace.record("\(pane) \(name)", read(rect), containerStep: nil) } }
                if let rect = rest[pane]?.pane { trace.settle("\(pane) \(name)", read(rect)) }
                guard let begin = start[pane]?.pane, let end = rest[pane]?.pane else { continue }
                let travel = read(end) - read(begin)
                guard abs(travel) > tolerance else { continue }
                for (index, frame) in frames.enumerated() {
                    guard let rect = frame[pane]?.pane else { continue }
                    let past = (read(rect) - read(end)) * (travel > 0 ? 1 : -1)
                    if past > tolerance { found.append("(a) \(pane) \(name) frame \(index): \(String(format: "%.1f", past)) pt past its rest") }
                }
            }
            // (c): the terminal's surface rides its pane: its leading and top edges never move away from their rest, and
            // never more in a frame than the pane's own leading and top edges.
            for (name, read, edge) in [("surface x", { (r: CGRect) in r.minX }, { (r: CGRect) in r.minX }),
                                       ("surface top", { (r: CGRect) in r.maxY }, { (r: CGRect) in r.maxY })] {
                var previous: CGRect?
                for frame in frames {
                    guard let sample = frame[pane], let surface = sample.surface else { continue }
                    let step = previous.map { abs(edge(sample.pane) - edge($0)) } ?? 0
                    previous = sample.pane
                    trace.record("\(pane) \(name)", read(surface), containerStep: step)
                }
                if let surface = rest[pane]?.surface { trace.settle("\(pane) \(name)", read(surface)) }
            }
        }
        found += trace.violations.map { "(\($0.kind == .afterEnd ? "d" : $0.element.contains("surface") ? "c" : "a")) \($0)" }
        // (b): one curve. Every moving edge of every pane is at the fraction of its travel the longest one is at.
        var moving: [(label: String, begin: CGFloat, end: CGFloat, read: (CGRect) -> CGFloat, pane: PaneID)] = []
        for pane in panes {
            guard let begin = start[pane]?.pane, let end = rest[pane]?.pane else { continue }
            for (name, read) in components where abs(read(end) - read(begin)) >= minTravel {
                moving.append(("\(pane) \(name)", read(begin), read(end), read, pane))
            }
        }
        guard let reference = moving.max(by: { abs($0.end - $0.begin) < abs($1.end - $1.begin) }) else { return found }
        for (index, frame) in frames.enumerated() {
            guard let shown = frame[reference.pane]?.pane else { continue }
            let progress = (reference.read(shown) - reference.begin) / (reference.end - reference.begin)
            for component in moving {
                guard let rect = frame[component.pane]?.pane else { continue }
                let expected = component.begin + progress * (component.end - component.begin)
                let off = component.read(rect) - expected
                if abs(off) > tolerance {
                    found.append("(b) frame \(index): \(component.label) is \(String(format: "%.1f", off)) pt off the curve "
                        + "\(reference.label) is on (\(String(format: "%.0f", progress * 100))% of its travel)")
                }
            }
        }
        return found
    }
}
