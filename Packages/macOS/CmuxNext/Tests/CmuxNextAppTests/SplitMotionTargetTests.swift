import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import GhosttyNextKit
import Testing

/// Leo 2026-11-06 (ask-fcac5debb4): "So after I close it, it does a jolt. Like, how does it sort of... it goes all the way
/// down and then back up. Like, but if it's at the top, it doesn't". A split's or a close's spring holds the terminal at its
/// final size on one edge of its pane (`TerminalSurfaceView` `restAt`). The edge was the bottom whenever the cursor was in
/// the lower half, but Ghostty pulls scrollback down only when the cursor is on the last row: a low prompt above it, with no
/// history to pull, showed its text a whole growth above its place at the spring's first frame, then slid back. A pane
/// that shrank always rode its top, so a prompt on the last row of a full screen snapped up at the first frame.
///
/// Each case runs the motion frame by frame (120 Hz ticks of the frame owner) and checks the spec's targets
/// (``MotionTargetTrace``): the prompt row and the pane's edges never move away from where they rest, the prompt never
/// moves more in a frame than its pane's edges do, and nothing moves after the landing.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SplitMotionTargetTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    static let stack = PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.stack)
    static let single = PaneGroundCoversPaneTests.column(.leaf("p1"))
    /// p1 over p2 over p3, even: Cmd-Shift-D on p2 of ``stack`` with even split sizing.
    static let thirds = PaneGroundCoversPaneTests.column(.split("x", axis: .vertical, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))

    /// p1 over p2; p2 closes, so p1 grows down. p1's prompt is in its lower half but not on its last row, with no history
    /// (Leo's recording): Ghostty keeps the text's top, so the prompt stays where it is.
    @Test func aCloseUnderALowPromptAboveTheLastRowKeepsThePromptInPlace() async throws {
        let rig = Rig(Self.stack, focused: "p1")
        defer { rig.close() }
        let rows = try Self.rows("p1", rig)
        try await Self.write("p1", rig, lines: rows * 3 / 4)
        let metrics = try Self.metrics("p1", rig)
        try #require(Int(metrics.cursor_row) * 2 >= Int(metrics.rows) && Int(metrics.cursor_row) < Int(metrics.rows) - 1,
                     "SETUP: p1's cursor row \(metrics.cursor_row) of \(metrics.rows) is not low and above the last row")
        let trace = try Self.trace("p1", rig) {
            _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        }
        Self.report("close, low prompt above the last row", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// p1 over p2; p2 closes. p1's prompt is on its last row with a long history: Ghostty pulls the history down, so the
    /// prompt rides p1's moving bottom edge to its rest (the bottom hold, kept).
    @Test func aCloseUnderAPromptOnTheLastRowRidesTheBottomEdge() async throws {
        let rig = Rig(Self.stack, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let trace = try Self.trace("p1", rig) {
            _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        }
        Self.report("close, prompt on the last row", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// p1 alone; a split opens p2 under it, so p1 shrinks. p1's prompt is on the last row of a full screen: Ghostty moves
    /// the top rows into the history, so the prompt rides p1's bottom edge up, never snapping up at the first frame.
    @Test func aSplitUnderAFullScreenKeepsThePromptOnTheBottomEdge() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let trace = try Self.trace("p1", rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        Self.report("split open, full screen", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// p1 alone with a short output at the top; a split opens under it. The text keeps its top (a guard).
    @Test func aSplitUnderAShortOutputKeepsItsTop() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 3)
        let trace = try Self.trace("p1", rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        Self.report("split open, short output", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// p1 over p2; p1 closes, so p2 grows up (ask-1cbd6386ac, Leo 2026-11-08: "the upwards thing. target gets
    /// recalculated ... shit doesn't look right, shit is not smooth"). Whatever p2 shows, its text rides the edge Ghostty
    /// keeps it on, and every edge goes straight to its rest.
    @Test(arguments: [3, 0, 200])
    func aCloseOfThePaneAboveGrowsThePaneBelowUpInOneMotion(lines: Int) async throws {
        let rig = Rig(Self.stack, focused: "p2")
        defer { rig.close() }
        let rows = try Self.rows("p2", rig)
        try await Self.write("p2", rig, lines: lines == 0 ? rows * 3 / 4 : lines)
        let trace = try Self.trace("p2", rig) {
            _ = try #require(rig.model.showPaneClose("p1"), "p1 did not close in the key's turn")
        }
        Self.report("close above, \(lines == 0 ? "low prompt" : "\(lines) lines")", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// p1 over p2; Cmd-Shift-D on p2 opens p3 under it with even sizing, so p1's bottom edge and all of p2 move up. Each
    /// of them goes straight to its rest on the one spring.
    @Test(arguments: ["p1", "p2"] as [PaneID])
    func aSplitDownUnderTwoPanesMovesEveryPaneUpInOneMotion(pane: PaneID) async throws {
        let rig = Rig(Self.stack, focused: "p2")
        defer { rig.close() }
        try await Self.write(pane, rig, lines: 200)
        let trace = try Self.trace(pane, rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.thirds)])
        }
        Self.report("split down under two, \(pane)", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// Two quick Cmd-Shift-D: p1 alone splits, and 6 frames in (50 ms) p2 splits again. The second split starts from what
    /// the window shows: p1's edges keep going one way to the new rest and land on the first motion's deadline, not one
    /// whole spring after the second press (design/motion.md: "A newly measured endpoint retargets from the currently
    /// drawn geometry and keeps the original deadline").
    @Test func aSecondSplitMidMotionRetargetsWithoutGoingBack() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let trace = try Self.trace("p1", rig, midway: (frame: 6, change: {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.thirds)])
        })) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        Self.report("split down twice", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    // MARK: - The rig

    /// Records `pane`'s prompt row and its pane's edges from the frame before `change` to the landing, then where they
    /// rest after one more layout pass.
    /// `midway` is a second change made after that many frames (a second key press during the motion).
    static func trace(_ pane: PaneID, _ rig: Rig, midway: (frame: Int, change: () throws -> Void)? = nil,
                      _ change: () throws -> Void) throws -> MotionTargetTrace {
        var trace = MotionTargetTrace()
        var edges = try Self.edges(pane, rig)
        let leftover = try Self.leftover(pane, rig)
        func sample() throws {
            let now = try Self.edges(pane, rig)
            let step = max(abs(now.top - edges.top), abs(now.bottom - edges.bottom))
            edges = now
            trace.record("\(pane) top", now.top, containerStep: nil)
            trace.record("\(pane) bottom", now.bottom, containerStep: nil)
            trace.record("\(pane) prompt", try Self.promptY(pane, rig), containerStep: step)
        }
        try sample()
        try change()
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try sample()
        var frames = 0
        var moving = true
        while frames < 240, moving {
            if frames == midway?.frame {
                try midway?.change()
                rig.root.syncWithModel()
                rig.root.layoutSubtreeIfNeeded()
            }
            moving = rig.frame()
            frames += 1
            try sample()
        }
        rig.commit()
        try #require(frames > 3, "the motion did not spring (\(frames) frames)")
        trace.deadline(Self.deadline)
        rig.root.layoutSubtreeIfNeeded()
        let rest = try Self.edges(pane, rig)
        trace.settle("\(pane) top", rest.top)
        trace.settle("\(pane) bottom", rest.bottom)
        trace.settle("\(pane) prompt", try Self.promptY(pane, rig))
        trace.allowFirstStep("\(pane) prompt", try Self.leftover(pane, rig) - leftover)
        return trace
    }

    /// The frame by which every tracked element shows at its rest: the `split` spring's 235 ms ceiling at 120 Hz, plus the
    /// key's frame.
    static let deadline = 30

    /// The pane host's top and bottom edges in the window.
    static func edges(_ pane: PaneID, _ rig: Rig) throws -> (top: CGFloat, bottom: CGFloat) {
        let host = try #require(rig.root.context.hosts[pane])
        let frame = host.convert(host.bounds, to: nil)
        return (frame.maxY, frame.minY)
    }

    /// The top of the cursor's row in the window: where the surface shows its grid's cursor row now.
    static func promptY(_ pane: PaneID, _ rig: Rig) throws -> CGFloat {
        let surface = try PaneContentPolicyTests.surface(pane, in: rig)
        let metrics = try Self.metrics(pane, rig)
        let frame = surface.convert(surface.bounds, to: nil)
        return frame.maxY - metrics.padding_top - CGFloat(metrics.cursor_row) * metrics.cell_height
    }

    /// The space under the grid's last row in its surface (less than a cell): where the final grid's rows sit against
    /// the edge the hold rides differs from the start grid's by the change in it.
    static func leftover(_ pane: PaneID, _ rig: Rig) throws -> CGFloat {
        let surface = try PaneContentPolicyTests.surface(pane, in: rig)
        let metrics = try Self.metrics(pane, rig)
        return surface.bounds.height - metrics.padding_top - CGFloat(metrics.rows) * metrics.cell_height
    }

    static func metrics(_ pane: PaneID, _ rig: Rig) throws -> ghostty_surface_grid_metrics_s {
        let view = try PaneContentPolicyTests.surface(pane, in: rig)
        let surface = try #require(view.surface, "\(pane) has no Ghostty surface")
        var metrics = ghostty_surface_grid_metrics_s()
        try #require(ghostty_surface_grid_metrics(surface, &metrics) && metrics.cursor_in_viewport, "\(pane)'s cursor is not in view")
        return metrics
    }

    static func rows(_ pane: PaneID, _ rig: Rig) throws -> Int {
        Int(try Self.metrics(pane, rig).rows)
    }

    /// `lines` lines of output, then a prompt; waits for the terminal's reply to a device attributes query after it.
    static func write(_ pane: PaneID, _ rig: Rig, lines: Int) async throws {
        let terminal = try #require(rig.provider.sessions[pane])
        terminal.io.send(.output(Data((String(repeating: "line\r\n", count: lines) + "$ \u{1b}[c").utf8)))
        await terminal.io.nextWrite()
    }

    static func report(_ name: String, _ trace: MotionTargetTrace) {
        print("motion-trace: \(name): \(trace.summary)")
        for line in trace.frames { print("motion-frames: \(name): \(line)") }
    }
}
