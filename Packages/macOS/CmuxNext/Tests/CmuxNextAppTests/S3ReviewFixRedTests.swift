import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// SCRATCH (never merged): the FRAME OWNER S3 review-fix regression tests from #34170 at head d67e03c46c8, run at
/// e79b747f538 (before the review fixes) to show each fails without its fix.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct S3ReviewFixRedTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// Two closes in a row (Cmd-W twice, the second before the first landed): p1 closes, then p2, beside p3, in one
    /// column. In every frame the pane hosts cover the column's width beyond the gap it rests at (the first closing pane
    /// rides the second, which rides p3), and every closing host is under every live host (p3 draws over the grounds it
    /// moves over).
    @Test func twoClosesInARowLeaveNoHole() throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(.split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))),
                      focused: "p3")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let screen = try rig.screen
        let line = screen.convert(screen.bounds, to: nil)
        // At rest only the gaps show (the column's edge gaps and its dividers).
        let atRest = try rig.uncoveredWidth(of: line)
        try #require(atRest < 20, "SETUP: \(atRest) pt of the column is not covered at rest")
        var widths: [(label: String, width: CGFloat)] = [], order: [String] = []
        func check(_ label: String) throws {
            widths.append((label, try rig.uncoveredWidth(of: line)))
            let hosts = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden }
            let closing = hosts.filter(\.showsClosingGround), live = hosts.filter { !$0.showsClosingGround }
            let highestClosing = closing.compactMap { screen.subviews.firstIndex(of: $0) }.max() ?? -1
            let lowestLive = live.compactMap { screen.subviews.firstIndex(of: $0) }.min() ?? Int.max
            if highestClosing > lowestLive { order.append("\(label): a closing host is above a live one") }
        }
        _ = try #require(rig.model.showPaneClose("p1"), "p1 did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try check("close 1")
        for frame in 1...4 {
            #expect(rig.frame(), "the first close landed after \(frame) frames")
            try check("frame \(frame)")
        }
        _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try check("close 2")
        var frames = 4
        try PaneContentPolicyTests.run(rig) { _ in
            frames += 1
            try check("frame \(frames)")
        }
        let rest = try rig.uncoveredWidth(of: line)
        let open = widths.filter { $0.width > max(atRest, rest) + 1 }
        #expect(frames > 10, "the closes did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show a hole in the column (\(atRest) pt before, \(rest) pt after): \(open.prefix(4))")
        #expect(order.isEmpty, "\(order.prefix(3))")
        #expect(screen.closingPanes.isEmpty, "a closing pane is left after the landing")
    }

    /// A press and its reverse in one key hold (Ctrl-Shift-H, then L 4 frames later, before the first lands): the panes
    /// rest where they began. Each terminal hears each press's final grid in that press's turn (the reverse one too, though
    /// it rests at the size the hold began at), and its surface takes no new size at the landing.
    @Test func aPressAndItsReverseInOneHoldSendEachGridInItsTurn() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await PaneContentPolicyTests.grids(pane, rig) }
        var start: [PaneID: (size: CGSize, grid: TerminalGridSize?)] = [:]
        for pane in panes {
            let surface = try PaneContentPolicyTests.surface(pane, in: rig)
            start[pane] = (surface.frame.size, surface.fittedGrid)
        }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in panes { atPress[pane] = try await PaneContentPolicyTests.grids(pane, rig) }
        for frame in 1...4 { #expect(rig.frame(), "the first press landed after \(frame) frames") }
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var atReverse: [PaneID: [TerminalGridSize]] = [:], sizeAtReverse: [PaneID: CGSize] = [:]
        for pane in panes {
            atReverse[pane] = try await PaneContentPolicyTests.grids(pane, rig)
            sizeAtReverse[pane] = try PaneContentPolicyTests.surface(pane, in: rig).frame.size
        }
        let frames = try PaneContentPolicyTests.run(rig)
        #expect(frames > 3, "the reverse press did not spring (\(frames) frames)")
        for pane in panes {
            let was = try #require(start[pane]), surface = try PaneContentPolicyTests.surface(pane, in: rig)
            let startGrid = try #require(was.grid, "SETUP: \(pane) fits no grid at rest")
            #expect(atPress[pane]?.count == 1 && atPress[pane]?.first != startGrid, "\(pane): the first press sent \(atPress[pane] ?? [])")
            #expect(atReverse[pane] == [startGrid], "\(pane): the reverse press sent \(atReverse[pane] ?? []), not the start grid \(startGrid)")
            #expect(try await PaneContentPolicyTests.grids(pane, rig).isEmpty, "\(pane) sent a grid at the landing")
            #expect(surface.frame.size == sizeAtReverse[pane] && surface.frame.size == was.size,
                    "\(pane)'s surface took \(surface.frame.size) at the landing (\(String(describing: sizeAtReverse[pane])) at the reverse press, \(was.size) at rest)")
        }
    }

    /// A tab switch to another terminal during a key hold: the terminal that joins follows the pane from its first frame,
    /// and its surface takes the size the press rests at (one grid), measured from the size the hold began at, never
    /// from the pane's size in the frame it joined.
    @Test func aTerminalThatJoinsDuringAHoldFollowsAndRestsAtTheFinalSize() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let pane = try #require(rig.root.context.hosts["p2"]?.content as? PaneContentView)
        let io = GridRecordingTerminalIO()
        let joining = TerminalSession(io: io)
        defer {
            joining.close()
            io.finish()
        }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...6 { _ = rig.frame() }
        // The tab switch: the joining terminal takes the pane's content area in the middle of the spring.
        pane.show(joining.view)
        rig.root.layoutSubtreeIfNeeded()
        var off: [String] = []
        let frames = try PaneContentPolicyTests.run(rig) { frame in
            let host = joining.view, area = try #require(host.superview)
            if host.frame.size != area.bounds.size { off.append("frame \(frame): the joining host \(host.frame.size) in \(area.bounds.size)") }
        }
        #expect(frames > 3, "the spring landed before the switch (\(frames) frames left)")
        #expect(off.isEmpty, "the joining terminal's host did not follow its pane: \(off.prefix(3))")
        let host = joining.view
        #expect(joining.surfaceView.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                "the joining surface rests at \(joining.surfaceView.frame.size) in a \(host.bounds.size) host")
        joining.surfaceView.bridge.takeUnretainedValue().input.focusGained()
        let grids = await io.gridsUntilMarker()
        let final = try #require(joining.surfaceView.fittedGrid)
        #expect(grids == [final], "the joining terminal asked its PTY for \(grids), not its final grid \(final) once")
    }

    /// A close taken back while motion is off (Reduce Motion turned on during the close): the pane comes back at its place
    /// at once, with no spring left running.
    @Test func aCloseTakenBackWithoutMotionSnapsToItsPlace() throws {
        // A split pair: closing p2 grows p1 over its place (a column at the strip's end has nothing that closes over it, and
        // hides at once as before).
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let host = try #require(rig.root.context.hosts["p2"])
        let rest = host.frame
        let close = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...5 { _ = rig.frame() }
        try #require(host.showsClosingGround && host.frame.width < rest.width - 1, "SETUP: p2 is not on its close spring (\(host.frame))")
        rig.root.context.reduceMotionOverride = true
        rig.model.cancelPaneClose(close)
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.root.context.hosts["p2"] === host, "the close taken back made a new host")
        #expect(abs(host.frame.minX - rest.minX) < 0.5 && abs(host.frame.width - rest.width) < 0.5, "p2 is at \(host.frame), not at its place \(rest)")
        #expect(try !rig.screen.hasMotion, "a spring still runs after a change with motion off")
    }

    /// A column at the strip's end closes (two columns, the right one closes). Whatever its neighbour does (it may stay or
    /// move to the strip's new place), the closing pane leaves no ground for the landing to take away in one frame: it hides
    /// at once when nothing closes over it, else in its last frame its ground that no live pane covers is under a point wide.
    @Test func aClosingPaneLeavesNoGroundForTheLanding() throws {
        let rig = Rig(.columns([LayoutColumn(id: "c0", width: 0.5, root: .leaf("p1")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p2"))]),
                      focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let host = try #require(rig.root.context.hosts["p2"])
        let screen = try rig.screen
        /// Along its middle line, the part of the closing ground no live host covers.
        func visibleGround() -> CGFloat {
            let ground = host.convert(host.bounds, to: nil)
            var spans = [(ground.minX, ground.maxX)]
            for live in screen.subviews.compactMap({ $0 as? PaneHostView }) where live !== host && !live.isHidden && !live.showsClosingGround {
                let shown = live.convert(live.bounds, to: nil)
                guard shown.minY <= ground.midY, shown.maxY >= ground.midY else { continue }
                spans = spans.flatMap { span in [(span.0, min(span.1, shown.minX)), (max(span.0, shown.maxX), span.1)].filter { $0.1 - $0.0 > 0 } }
            }
            return spans.reduce(0) { $0 + ($1.1 - $1.0) }
        }
        _ = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var last: CGFloat?
        var frames = 0
        while frames < 240, host.superview != nil, host.showsClosingGround, rig.frame() {
            frames += 1
            if host.superview != nil, host.showsClosingGround { last = visibleGround() }
        }
        try PaneContentPolicyTests.run(rig)
        if let last { #expect(last < 1, "the closing pane's last frame shows \(last) pt of its ground: the landing takes it away in one frame") }
        #expect(host.superview == nil, "the closed host is left in the tree after the landing")
    }
}
