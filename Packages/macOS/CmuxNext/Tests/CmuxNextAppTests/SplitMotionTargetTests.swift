import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import GhosttyNextKit
import Testing

/// Where a terminal's text shows when a split or a close resizes its pane. Such a change is one commit
/// (`ScreenContentView+SnapFrame`): its own turn shows the layout before it, the first frame tick shows the layout after
/// it, each pane at its rest and each terminal at its pane's new size, and nothing moves after that tick. In that frame
/// the text is on the edge Ghostty keeps it on when its grid changes (`PageList.resizeWithoutReflow`):
/// - more rows: Ghostty pulls scrollback down only when the cursor is on the last row, so a prompt on the last row stays
///   on the pane's bottom edge; otherwise the new rows are blank ones under the text, which keeps its top;
/// - fewer rows: Ghostty trims the blank rows under the cursor first and moves only the rest into the history, so a
///   prompt on the last row of a full screen stays on the bottom edge, and a short output keeps its top.
///
/// Each case reads the pane host's edges and the prompt row from the view tree at rest before the change, in the
/// change's own turn, after the first frame tick (a 120 Hz tick of the frame owner), after each of the 3 ticks that
/// follow, and after the commit's work (``Commit``).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SplitMotionTargetTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    static let stack = PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.stack)
    static let single = PaneGroundCoversPaneTests.column(.leaf("p1"))
    /// p1 over p2 over p3, even: Cmd-Shift-D on p2 of ``stack`` with even split sizing.
    static let thirds = PaneGroundCoversPaneTests.column(.split("x", axis: .vertical, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                b: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))

    /// p1 over p2; p2 closes, so p1 grows down. p1's prompt is in its lower half but not on its last row, with no history:
    /// Ghostty keeps the text's top, so the frame that shows the close shows the prompt where it was.
    @Test func aCloseUnderALowPromptAboveTheLastRowKeepsThePromptInPlace() async throws {
        let rig = Rig(Self.stack, focused: "p1")
        defer { rig.close() }
        let rows = try Self.rows("p1", rig)
        try await Self.write("p1", rig, lines: rows * 3 / 4)
        let metrics = try Self.metrics("p1", rig)
        try #require(Int(metrics.cursor_row) * 2 >= Int(metrics.rows) && Int(metrics.cursor_row) < Int(metrics.rows) - 1,
                     "SETUP: p1's cursor row \(metrics.cursor_row) of \(metrics.rows) is not low and above the last row")
        let commit = try Self.commit("p1", rig, closing: "p2") {
            _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        }
        Self.report("close, low prompt above the last row", commit)
        Self.expectOneFrame(commit)
        #expect(commit.before.bottom - commit.first.bottom > 100, "the close did not grow p1 down: \(commit.before) -> \(commit.first)")
        #expect(commit.promptKeepsTop && abs(commit.first.top - commit.before.top) <= Place.slack,
                "the prompt left its place: \(commit.before) -> \(commit.first)")
    }

    /// p1 over p2; p2 closes. p1's prompt is on its last row with a long history: Ghostty pulls the history down, so the
    /// frame that shows the close shows the prompt on p1's new bottom edge.
    @Test func aCloseUnderAPromptOnTheLastRowShowsThePromptOnTheNewBottomEdge() async throws {
        let rig = Rig(Self.stack, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let commit = try Self.commit("p1", rig, closing: "p2") {
            _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        }
        Self.report("close, prompt on the last row", commit)
        Self.expectOneFrame(commit)
        #expect(commit.before.bottom - commit.first.bottom > 100, "the close did not grow p1 down: \(commit.before) -> \(commit.first)")
        #expect(commit.promptKeepsBottom, "the prompt is not on p1's new bottom edge: \(commit.before) -> \(commit.first)")
    }

    /// p1 alone; a split opens p2 under it, so p1 shrinks. p1's prompt is on the last row of a full screen: Ghostty moves
    /// the top rows into the history, so the frame that shows the split shows the prompt on p1's new bottom edge.
    @Test func aSplitUnderAFullScreenKeepsThePromptOnTheBottomEdge() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let commit = try Self.commit("p1", rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        Self.report("split open, full screen", commit)
        Self.expectOneFrame(commit)
        #expect(commit.first.bottom - commit.before.bottom > 100, "the split did not move p1's bottom edge up: \(commit.before) -> \(commit.first)")
        #expect(commit.promptKeepsBottom, "the prompt is not on p1's new bottom edge: \(commit.before) -> \(commit.first)")
    }

    /// p1 alone with a short output at the top; a split opens under it. The text keeps its top (a guard): the frame that
    /// shows the split shows the prompt where it was.
    @Test func aSplitUnderAShortOutputKeepsItsTop() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 3)
        let commit = try Self.commit("p1", rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        Self.report("split open, short output", commit)
        Self.expectOneFrame(commit)
        #expect(commit.first.bottom - commit.before.bottom > 100, "the split did not move p1's bottom edge up: \(commit.before) -> \(commit.first)")
        #expect(commit.promptKeepsTop && abs(commit.first.top - commit.before.top) <= Place.slack,
                "the prompt left its place: \(commit.before) -> \(commit.first)")
    }

    /// p1 over p2; p1 closes, so p2 grows up. Whatever p2 shows, the frame that shows the close shows p2's edges at their
    /// rest and its text on the edge Ghostty keeps it on: a prompt on the last row, with its history, stays on the bottom
    /// edge; a short output and a prompt above the last row keep their place under p2's top edge, which moved up.
    @Test(arguments: [3, 0, 200])
    func aCloseOfThePaneAboveGrowsThePaneBelowUpInOneFrame(lines: Int) async throws {
        let rig = Rig(Self.stack, focused: "p2")
        defer { rig.close() }
        let rows = try Self.rows("p2", rig)
        try await Self.write("p2", rig, lines: lines == 0 ? rows * 3 / 4 : lines)
        let commit = try Self.commit("p2", rig, closing: "p1") {
            _ = try #require(rig.model.showPaneClose("p1"), "p1 did not close in the key's turn")
        }
        Self.report("close above, \(lines == 0 ? "low prompt" : "\(lines) lines")", commit)
        Self.expectOneFrame(commit)
        #expect(commit.first.top - commit.before.top > 100 && abs(commit.first.bottom - commit.before.bottom) <= Place.slack,
                "the close did not grow p2 up: \(commit.before) -> \(commit.first)")
        if lines == 200 {
            #expect(commit.promptKeepsBottom, "the prompt on the last row left p2's bottom edge: \(commit.before) -> \(commit.first)")
        } else {
            #expect(commit.promptKeepsTop, "the text left its place under p2's top edge: \(commit.before) -> \(commit.first)")
        }
    }

    /// p1 over p2; Cmd-Shift-D on p2 opens p3 under it with even sizing, so p1's bottom edge and all of p2 move up. The
    /// frame that shows the split shows each of them at its rest, its prompt (on the last row of a full screen) on its
    /// new bottom edge.
    @Test(arguments: ["p1", "p2"] as [PaneID])
    func aSplitDownUnderTwoPanesShowsEveryPaneAtItsRestInOneFrame(pane: PaneID) async throws {
        let rig = Rig(Self.stack, focused: "p2")
        defer { rig.close() }
        try await Self.write(pane, rig, lines: 200)
        let commit = try Self.commit(pane, rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.thirds)])
        }
        Self.report("split down under two, \(pane)", commit)
        Self.expectOneFrame(commit)
        #expect(commit.first.bottom - commit.before.bottom > 50, "the split did not move \(pane)'s bottom edge up: \(commit.before) -> \(commit.first)")
        #expect(commit.promptKeepsBottom, "the prompt is not on \(pane)'s new bottom edge: \(commit.before) -> \(commit.first)")
    }

    /// Two Cmd-Shift-D one display frame apart: p1 alone splits, and right after the frame tick that shows that split, p2
    /// splits again. Each split is one commit: its own turn shows what the window showed before it (for the second one,
    /// the first split, whole), its frame tick shows p1 at that layout's rest with its prompt on its bottom edge, and
    /// p1's bottom edge only goes up. `PaneLayoutCommitTests.twoLayoutChangesShowOnlyWholeLayouts` holds the same for
    /// every pane and divider, and for two changes in one turn.
    @Test func aSecondSplitOneFrameAfterTheFirstShowsEachSplitWhole() async throws {
        let rig = Rig(Self.single, focused: "p1")
        defer { rig.close() }
        try await Self.write("p1", rig, lines: 200)
        let halves = try Self.commit("p1", rig, settles: false) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.stack)])
        }
        let thirds = try Self.commit("p1", rig) {
            rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.thirds)])
        }
        Self.report("split down twice, first split", halves)
        Self.report("split down twice, second split", thirds)
        Self.expectOneFrame(halves)
        Self.expectOneFrame(thirds)
        #expect(halves.first.bottom - halves.before.bottom > 100 && thirds.first.bottom - thirds.before.bottom > 50,
                "p1's bottom edge did not go up at each split: \(halves.before) -> \(halves.first) -> \(thirds.first)")
        #expect(halves.promptKeepsBottom && thirds.promptKeepsBottom,
                "the prompt left p1's bottom edge: \(halves.before) -> \(halves.first) -> \(thirds.first)")
    }

    // MARK: - The rig

    /// Where one pane shows in the window (y grows up): its host's top and bottom edges, and the top of its cursor's row.
    struct Place {
        /// The slack below which a difference is rounding (a 2x backing pixel is 0.5 pt).
        static let slack: CGFloat = 0.5

        var top: CGFloat
        var bottom: CGFloat
        var prompt: CGFloat

        func isNear(_ other: Place) -> Bool {
            abs(top - other.top) <= Place.slack && abs(bottom - other.bottom) <= Place.slack && abs(prompt - other.prompt) <= Place.slack
        }
    }

    /// What the window showed of one pane around one layout change (``commit(_:_:closing:settles:_:)``).
    struct Commit {
        /// At rest before the change.
        let before: Place
        /// In the change's own turn, after its layout pass.
        let turn: Place
        /// After the first frame tick.
        let first: Place
        /// After each of the 3 frame ticks that follow, then after the commit's work and one more layout pass.
        let later: [Place]
        /// The space under the grid's last row before the change and after it (``leftover(_:_:)``): less than a cell, and
        /// another one for another grid.
        let leftover: (before: CGFloat, after: CGFloat)
        /// Each part of the commit's contract that the view tree broke, one line each.
        let breaks: [String]

        /// How far a prompt's place against a pane edge may differ between the two grids: the change of the leftover.
        var promptSlack: CGFloat { abs(leftover.after - leftover.before) + Place.slack }
        /// The change's own turn shows the pane and its prompt where they were.
        var turnShowsTheLayoutBefore: Bool { turn.isNear(before) }
        /// The first frame tick showed the pane and its prompt at their rest: nothing moved after it.
        var firstFrameIsTheRest: Bool { later.allSatisfy { $0.isNear(first) } }
        /// The prompt keeps its place under the pane's top edge: the text keeps its top.
        var promptKeepsTop: Bool { abs((first.top - first.prompt) - (before.top - before.prompt)) <= promptSlack }
        /// The prompt keeps its place over the pane's bottom edge: a prompt on the last row stays on it.
        var promptKeepsBottom: Bool { abs((first.prompt - first.bottom) - (before.prompt - before.bottom)) <= promptSlack }
    }

    /// Makes `change` and records `pane` around it (``Commit``): at rest before it, in its own turn, after the first frame
    /// tick and, with `settles`, after each of the 3 ticks that follow and after the commit's work and one more layout
    /// pass. `closing`: the pane the change closes. ``Commit/breaks`` names every part of the commit's contract that the
    /// view tree broke: a pane host that moved in the change's own turn, a closed pane hidden before the change showed or
    /// shown after it, a screen in motion, a frame tick that asks for more frames, a pane host off its rest rect after
    /// the first tick.
    static func commit(_ pane: PaneID, _ rig: Rig, closing: PaneID? = nil, settles: Bool = true,
                       _ change: () throws -> Void) throws -> Commit {
        let screen = try rig.screen
        let before = try Self.place(pane, rig), leftoverBefore = try Self.leftover(pane, rig)
        let hosts = rig.root.context.hosts.map { (name: $0.key.rawValue, host: $0.value, frame: $0.value.frame) }
        let closed = closing.flatMap { rig.root.context.hosts[$0] }
        var breaks: [String] = []

        // The change's own turn: every pane host shows where it showed, the closed pane too, and nothing springs.
        try change()
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        let turn = try Self.place(pane, rig)
        for entry in hosts where entry.host.frame != entry.frame {
            breaks.append("the change's own turn moved \(entry.name)'s host from \(entry.frame) to \(entry.host.frame)")
        }
        if closed?.isHidden == true { breaks.append("the change's own turn hid the closed pane") }
        if screen.hasMotion { breaks.append("the change put the screen in motion") }

        // The first frame tick: every pane host of the new layout is at its rest rect, and the closed pane is hidden.
        if rig.frame() { breaks.append("the first frame tick asks for more frames") }
        let first = try Self.place(pane, rig)
        for id in screen.paneFrames.keys {
            guard let host = rig.root.context.hosts[id], let rest = screen.displayedFrame(of: id) else {
                breaks.append("\(id.rawValue) has no host after the first frame tick")
                continue
            }
            if host.frame != rest { breaks.append("the first frame tick left \(id.rawValue)'s host at \(host.frame), not at its rest \(rest)") }
        }
        if closed?.isHidden == false { breaks.append("the closed pane still shows after the first frame tick") }

        // Nothing moves after it.
        var later: [Place] = []
        if settles {
            for tick in 2...4 {
                if rig.frame() { breaks.append("frame tick \(tick) still moves something") }
                later.append(try Self.place(pane, rig))
            }
            rig.commit()
            later.append(try Self.place(pane, rig))
        }
        if screen.hasMotion { breaks.append("the screen is in motion after the change showed") }
        let leftoverAfter = try Self.leftover(pane, rig)
        return Commit(before: before, turn: turn, first: first, later: later, leftover: (leftoverBefore, leftoverAfter), breaks: breaks)
    }

    /// The commit's contract, the same for every case: the change's own turn shows the layout before it, the first frame
    /// tick shows the layout after it with the pane and its prompt at their rest, and nothing moves after that tick.
    static func expectOneFrame(_ commit: Commit) {
        #expect(commit.breaks.isEmpty, "\(commit.breaks.count) parts of the commit broke: \(commit.breaks.prefix(4))")
        #expect(commit.turnShowsTheLayoutBefore, "the change's own turn moved the pane or its prompt: \(commit.before) -> \(commit.turn)")
        #expect(commit.firstFrameIsTheRest,
                "the pane or its prompt moved after the frame that showed the change: \(commit.first) -> \(commit.later)")
    }

    /// Where `pane`'s host edges and its prompt row show now.
    static func place(_ pane: PaneID, _ rig: Rig) throws -> Place {
        let edges = try Self.edges(pane, rig)
        return Place(top: edges.top, bottom: edges.bottom, prompt: try Self.promptY(pane, rig))
    }

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

    /// The space under the grid's last row in its surface (less than a cell). Another grid has another one, so a prompt on
    /// the last row sits that much nearer to its pane's bottom edge, or farther from it, after the change.
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

    static func report(_ name: String, _ commit: Commit) {
        print("layout-commit: \(name): before \(commit.before), own turn \(commit.turn), first tick \(commit.first), "
            + "rest \(commit.later.last ?? commit.first)")
    }
}
