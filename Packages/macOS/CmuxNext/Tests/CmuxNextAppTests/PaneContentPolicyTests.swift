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

/// FRAME OWNER REFACTOR S3: the rules the content policy keeps beside PaneGroundCoversPaneTests (the shell never shows
/// inside a pane rect).
/// - In a key resize the terminal surface (the producer) stays fixed at the pane edge that does not move, for each side
///   a pane can grow or shrink on, while its host (the container) follows the pane in every frame.
/// - One grid per press: each terminal asks its PTY for its final grid once, by the press's first frame tick (FRAME
///   OWNER S1B; it was the key's turn), and its surface takes a
///   new size at most once (no surface `setFrameSize` per frame, no reflow per frame).
/// - S3c: a closing pane shows its ground as it was at the close, the same host comes back when a close is taken back,
///   and nothing of it is left in the view tree after the landing.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentPolicyTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// The terminal surface of `pane`, and where it shows in the window.
    static func surface(_ pane: PaneID, in rig: Rig) throws -> TerminalSurfaceView {
        try #require(rig.provider.sessions[pane]?.session.surfaceView, "\(pane) shows no terminal")
    }

    /// Steps the motion to its landing and its release; `frame` runs after each frame's layout pass. The frame count.
    @discardableResult
    static func run(_ rig: Rig, frame: (Int) throws -> Void = { _ in }) rethrows -> Int {
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            try frame(frames)
        }
        rig.commit()
        return frames
    }

    // MARK: Note 2: the surface stays fixed at the pane edge that does not move

    /// One press on each side of each axis. p2 grows to the left (H: its leading edge moves, the surface rides the
    /// trailing edge), p1 grows to the right (L on p1: the trailing edge moves, it rides the leading edge), p2 grows up
    /// (K: its top edge moves, it rides the bottom), p1 grows down (J on p1: its bottom edge moves, it rides the top).
    /// The shrinking pane beside each rides its own edge that stays. The host follows the pane in every frame.
    nonisolated struct Side: Sendable, CustomTestStringConvertible {
        let vertical: Bool
        let pressed: PaneID
        let direction: LayoutDirection
        var testDescription: String { "\(pressed) \(direction)" }
    }

    nonisolated static let sides: [Side] = [
        Side(vertical: false, pressed: "p2", direction: .left), Side(vertical: false, pressed: "p1", direction: .right),
        Side(vertical: true, pressed: "p2", direction: .up), Side(vertical: true, pressed: "p1", direction: .down),
    ]

    @Test(arguments: sides)
    func theSurfaceStaysAtThePaneEdgeThatDoesNotMove(_ side: Side) throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(side.vertical ? PaneGroundCoversPaneTests.stack : PaneGroundCoversPaneTests.pair),
                      focused: side.pressed)
        defer { rig.close() }
        var start: [PaneID: CGRect] = [:]
        for pane in ["p1", "p2"] as [PaneID] {
            let host = try #require(rig.root.context.hosts[pane])
            start[pane] = host.convert(host.roundedRect, to: nil)
        }
        #expect(PaneResize.press(side.pressed, side.direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var off: [String] = []
        let frames = try Self.run(rig) { frame in
            for pane in ["p1", "p2"] as [PaneID] {
                let host = try #require(rig.root.context.hosts[pane]), was = try #require(start[pane])
                let area = host.convert(host.roundedRect, to: nil)
                let shown = try Self.surface(pane, in: rig)
                let surface = shown.convert(shown.bounds, to: nil)
                let terminal = try #require(rig.provider.sessions[pane]?.session.view)
                let ground = terminal.convert(terminal.bounds, to: nil)
                // The edge that stays: the one whose window position is where it was before the press.
                let edges: [(String, CGFloat, CGFloat, CGFloat)] = side.vertical
                    ? [("bottom", area.minY, was.minY, surface.minY), ("top", area.maxY, was.maxY, surface.maxY)]
                    : [("leading", area.minX, was.minX, surface.minX), ("trailing", area.maxX, was.maxX, surface.maxX)]
                for (name, now, before, at) in edges where abs(now - before) < 0.5 {
                    // A padded surface sits one padding inside the host: compare it with where it sat at rest.
                    let inset = at - now
                    if abs(inset) > 12 { off.append("frame \(frame): \(pane)'s surface left the \(name) edge that stays (\(at) vs \(now))") }
                }
                if !ground.insetBy(dx: -1, dy: -1).contains(area) {
                    off.append("frame \(frame): \(pane)'s host \(ground) does not follow its pane \(area)")
                }
            }
        }
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames off: \(off.prefix(3))")
    }

    // MARK: Note 3: one grid per press

    /// One press with the switch on: each terminal asks its PTY for one grid, the final one, by the press's first frame; its
    /// surface takes a new size at most once in the whole press (none per frame), and none at the landing.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressSizesEachSurfaceOnceAndSendsOneGrid(direction: LayoutDirection) async throws {
        let vertical = direction == .up || direction == .down
        let rig = Rig(PaneGroundCoversPaneTests.column(vertical ? PaneGroundCoversPaneTests.stack : PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var sizes: [PaneID: [CGSize]] = [:]
        var last: [PaneID: CGSize] = [:]
        for pane in panes { last[pane] = try Self.surface(pane, in: rig).frame.size }
        func note() throws {
            for pane in panes {
                let size = try Self.surface(pane, in: rig).frame.size
                if size != last[pane] { sizes[pane, default: []].append(size) }
                last[pane] = size
            }
        }
        let reportsBefore = TerminalSurfaceView.gridReports
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try note()
        let frames = try Self.run(rig) { _ in try note() }
        try note()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(TerminalSurfaceView.gridReports - reportsBefore <= UInt64(panes.count), "more grid reports than terminals for one press")
        for pane in panes {
            let grids = try await Self.grids(pane, rig)
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            #expect(grids == [final], "\(pane) asked its PTY for \(grids), not its final grid \(final) once")
            #expect((sizes[pane] ?? []).count <= 1, "\(pane)'s surface took \(sizes[pane]?.count ?? 0) sizes in one press: \(sizes[pane] ?? [])")
        }
    }

    /// A held key (three Ctrl-Shift-H presses 4 frames apart retarget one spring): each terminal asks its PTY for the
    /// final grid of each press, once, by that press's first frame (at most one grid per press, the last one the final),
    /// and its surface takes a new size only in a press's turn or first frame, never in another frame or at the landing.
    @Test func aHeldKeySizesEachSurfaceOnlyInAPressTurn() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var last: [PaneID: CGSize] = [:]
        for pane in panes { last[pane] = try Self.surface(pane, in: rig).frame.size }
        var inFrames: [String] = [], grids: [PaneID: [TerminalGridSize]] = [:]
        func note(_ label: String, frame: Bool) throws {
            for pane in panes {
                let size = try Self.surface(pane, in: rig).frame.size
                if size != last[pane], frame { inFrames.append("\(label): \(pane) \(size)") }
                last[pane] = size
            }
        }
        var frames = 0
        for press in 1...3 {
            #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root), "press \(press) moved nothing")
            rig.root.syncWithModel()
            // The press's first frame is its own (S1B): its rest size and its grid go there.
            if rig.frame() { frames += 1 }
            try note("press \(press)", frame: false)
            for pane in panes { grids[pane, default: []] += try await Self.grids(pane, rig) }
            for _ in 1...3 where rig.frame() {
                frames += 1
                try note("frame \(frames)", frame: true)
            }
        }
        try Self.run(rig) { _ in
            frames += 1
            try note("frame \(frames)", frame: true)
        }
        try note("after the landing", frame: true)
        #expect(frames > 12, "the presses did not spring (\(frames) frames)")
        #expect(inFrames.isEmpty, "a surface took a new size outside a press's turn and first frame: \(inFrames.prefix(3))")
        for pane in panes {
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            let sent = (grids[pane] ?? []) + (try await Self.grids(pane, rig))
            #expect(sent.count <= 3 && sent.last == final, "\(pane) asked its PTY for \(sent) over 3 presses (final \(final))")
        }
    }

    /// A press and its reverse in one key hold (Ctrl-Shift-H, then L 4 frames later, before the first lands): the panes
    /// rest where they began. Each terminal hears each press's final grid by that press's first frame (the reverse one too, though
    /// it rests at the size the hold began at), and its surface takes no new size at the landing.
    @Test func aPressAndItsReverseInOneHoldSendEachGridInItsTurn() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var start: [PaneID: (size: CGSize, grid: TerminalGridSize?)] = [:]
        for pane in panes {
            let surface = try Self.surface(pane, in: rig)
            start[pane] = (surface.frame.size, surface.fittedGrid)
        }
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(rig.frame(), "the first press did not spring")
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in panes { atPress[pane] = try await Self.grids(pane, rig) }
        for frame in 2...4 { #expect(rig.frame(), "the first press landed after \(frame) frames") }
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(rig.frame(), "the reverse press did not spring")
        var atReverse: [PaneID: [TerminalGridSize]] = [:], sizeAtReverse: [PaneID: CGSize] = [:]
        for pane in panes {
            atReverse[pane] = try await Self.grids(pane, rig)
            sizeAtReverse[pane] = try Self.surface(pane, in: rig).frame.size
        }
        let frames = try Self.run(rig)
        #expect(frames > 3, "the reverse press did not spring (\(frames) frames)")
        for pane in panes {
            let was = try #require(start[pane]), surface = try Self.surface(pane, in: rig)
            let startGrid = try #require(was.grid, "SETUP: \(pane) fits no grid at rest")
            #expect(atPress[pane]?.count == 1 && atPress[pane]?.first != startGrid, "\(pane): the first press sent \(atPress[pane] ?? [])")
            #expect(atReverse[pane] == [startGrid], "\(pane): the reverse press sent \(atReverse[pane] ?? []), not the start grid \(startGrid)")
            #expect(try await Self.grids(pane, rig).isEmpty, "\(pane) sent a grid at the landing")
            #expect(surface.frame.size == sizeAtReverse[pane] && surface.frame.size == was.size,
                    "\(pane)'s surface took \(surface.frame.size) at the landing (\(String(describing: sizeAtReverse[pane])) at the reverse press, \(was.size) at rest)")
        }
    }

    /// The grids `pane`'s terminal asked its PTY for since the last call (a focus report after them is the marker).
    static func grids(_ pane: PaneID, _ rig: Rig) async throws -> [TerminalGridSize] {
        let session = try #require(rig.provider.sessions[pane])
        session.session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
        return await session.io.gridsUntilMarker()
    }

    /// A tab switch to another terminal during a key hold: the terminal that joins follows the pane from its first frame,
    /// and its surface takes the size the press rests at (one grid), measured from the size the hold began at, never
    /// from the pane's size in the frame it joined.
    @Test func aTerminalThatJoinsDuringAHoldFollowsAndRestsAtTheFinalSize() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
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
        let frames = try Self.run(rig) { frame in
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

    // MARK: Note 5: S3c

    /// A closing pane shows the ground it had at the close (a theme change during the close changes nothing), it shows no
    /// content, and after the landing its host, ring and content are gone from the view tree.
    @Test func aClosingPaneShowsItsGroundReadAtTheCloseAndLeavesNothingBehind() throws {
        let rig = Rig(.columns([LayoutColumn(id: "c0", width: 1.0 / 3, root: .leaf("p1")), LayoutColumn(id: "c1", width: 1.0 / 3, root: .leaf("p2")),
                                LayoutColumn(id: "c2", width: 1.0 / 3, root: .leaf("p3"))]), focused: "p2")
        defer { rig.close() }
        let host = try #require(rig.root.context.hosts["p2"])
        let terminal = try #require(rig.provider.sessions["p2"]?.session.view)
        let ground = try #require(terminal.layer?.backgroundColor, "SETUP: the terminal paints no ground")
        let layersBefore = Self.layerCount(rig.root), closedLayers = Self.layerCount(host) + Self.layerCount(host.chrome)
        try #require(closedLayers > 2, "SETUP: the closing pane has \(closedLayers) layers")
        _ = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(!host.isHidden && host.showsClosingGround, "the closing host is not shown with its ground")
        #expect(host.content.isHidden, "the closing pane still shows its content")
        // A repaint of the terminal during the close does not reach the closing ground: it was read at the close.
        terminal.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        var shownGrounds: [CGColor?] = []
        var widths: [CGFloat] = []
        try Self.run(rig) { _ in
            if host.superview != nil {
                shownGrounds.append(host.clipView.layer?.backgroundColor)
                widths.append(host.frame.width)
            }
        }
        #expect(!widths.isEmpty, "the closing pane did not show on its close spring")
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0.1 <= $0.0 + 0.5 }, "the closing pane grew: \(widths.prefix(8))")
        #expect(shownGrounds.allSatisfy { $0 == ground }, "the closing ground was not the one read at the close")
        #expect(host.superview == nil && host.chrome.superview == nil, "the closing host or its ring is left in the view tree")
        #expect(rig.root.context.closingHost("p2", of: "s") == nil, "the closing host is still retired after the landing")
        #expect(!Self.contains(rig.root, host) && !Self.contains(rig.root, host.content), "the closed pane's views are left in the window")
        let layersAfter = Self.layerCount(rig.root)
        #expect(layersAfter <= layersBefore - closedLayers,
                "the window has \(layersAfter) layers after the landing; \(layersBefore) before the close less the closed pane's \(closedLayers)")
        #expect(host.layer?.superlayer == nil && host.chrome.layer?.superlayer == nil, "a closed pane's layer is still in a layer tree")
    }

    /// Two closes in a row (Cmd-W twice, the second before the first landed): p1 closes, then p2, beside p3, in one
    /// column. In every frame the pane hosts cover the column's width beyond the gap it rests at (the first closing pane
    /// rides the second, which rides p3), and every closing host is under every live host (p3 draws over the grounds it
    /// moves over).
    @Test func twoClosesInARowLeaveNoHole() throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(.split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))),
                      focused: "p3")
        defer { rig.close() }
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
        try Self.run(rig) { _ in
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

    /// A close taken back before it landed shows the same host again, with its content, from where its closing frame
    /// showed: no new host, no new terminal.
    @Test func aCloseTakenBackShowsTheSameHost() throws {
        // A split pair: closing p2 grows p1 over its place (a column at the strip's end has nothing that closes over it, and
        // hides at once as before).
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let host = try #require(rig.root.context.hosts["p2"])
        let session = try #require(rig.provider.sessions["p2"]?.session)
        let close = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...5 { _ = rig.frame() }
        let shown = host.frame
        #expect(host.showsClosingGround && shown.width > 1, "SETUP: p2 is not on its close spring (\(shown))")
        rig.model.cancelPaneClose(close)
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.root.context.hosts["p2"] === host, "the close taken back made a new host")
        #expect(!host.showsClosingGround && !host.content.isHidden, "the host taken back does not show its content")
        #expect(abs(host.frame.width - shown.width) < 24, "the host taken back jumped from \(shown) to \(host.frame)")
        try Self.run(rig)
        #expect(rig.provider.sessions["p2"]?.session === session, "the close taken back made a new terminal")
        #expect(host.superview != nil && !host.isHidden, "the host taken back is not in the layout after the landing")
    }

    /// A close taken back while motion is off (Reduce Motion turned on during the close): the pane comes back at its place
    /// at once, with no spring left running.
    @Test func aCloseTakenBackWithoutMotionSnapsToItsPlace() throws {
        // A split pair: closing p2 grows p1 over its place (a column at the strip's end has nothing that closes over it, and
        // hides at once as before).
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
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
        try Self.run(rig)
        if let last { #expect(last < 1, "the closing pane's last frame shows \(last) pt of its ground: the landing takes it away in one frame") }
        #expect(host.superview == nil, "the closed host is left in the tree after the landing")
    }

    /// The layers of `view`'s tree: each view's backing layer, the views under it included.
    static func layerCount(_ view: NSView) -> Int {
        (view.layer == nil ? 0 : 1) + view.subviews.reduce(0) { $0 + layerCount($1) }
    }

    static func contains(_ root: NSView, _ view: NSView) -> Bool { view.isDescendant(of: root) }
}
