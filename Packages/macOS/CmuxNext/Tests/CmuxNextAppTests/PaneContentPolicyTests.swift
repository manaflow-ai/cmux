import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import GhosttyNextKit
import Testing

/// FRAME OWNER REFACTOR S3: the rules the content policy keeps beside PaneGroundCoversPaneTests (the shell never shows
/// inside a pane rect).
/// - cmux-ad m18 (replaces m6's "program size per press" and the switch-off key hold, whose `...WithTheSwitchOff` tests
///   are gone; cmux-ad m19 deleted the switch): in every frame each terminal's surface has the size its
///   pane shows it at, so its text follows the pane (S3 held it at one size per press: the text froze, then jumped;
///   Lawrence on dogfood 363e39f2). Each PTY gets the view's grid at most
///   once per 25 ms, the newest, and ends at the landing's grid (`TerminalGridReportCoalescer`; ``grids(_:_:)`` ends the
///   window before it reads). A window that draws nothing shows each size at once; one that draws (a display worker)
///   shows a size only in the commit that presents the frame Ghostty drew at it (FRAME OWNER S4,
///   ``TerminalFramePresenter``), so the size checks step whole refreshes (``refresh(_:)``), never bare frames.
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

    /// One refresh as the app runs it: the frame's step and layout pass, then its commit, before which the window's
    /// ``TerminalFramePresenter`` gives each terminal its new bounds with the frame Ghostty drew at them. In a window that
    /// draws (a display worker), a frame stepped with no commit (``Rig/frame()``) leaves each new size waiting for that
    /// commit: the surface kept the size of the last commit, which came only at the test's next await (T-KEYS 2: 3 cases
    /// red on display workers at 5840aea3a60 and 2296568ae00, every surface off its pane with the presenter at "request").
    /// The refresh commits again while a terminal's frame is not drawn yet, at most 2 s: here the renderer keeps up with
    /// the display; TerminalKeyResizeFrameTests counts the refreshes a terminal keeps its old size when it does not.
    /// Whether the motion still moves.
    static func refresh(_ rig: Rig) async -> Bool {
        let moving = rig.frame()
        await landDrawnFrames(rig)
        return moving
    }

    /// ``run(_:frame:)`` in whole refreshes (``refresh(_:)``): `frame` runs after each frame's commit; the landing's
    /// release and its commit come last. The frame count.
    @discardableResult
    static func runRefreshes(_ rig: Rig, frame: (Int) throws -> Void = { _ in }) async rethrows -> Int {
        var frames = 0
        while frames < 240, await refresh(rig) {
            frames += 1
            try frame(frames)
        }
        rig.commit()
        await landDrawnFrames(rig)
        return frames
    }

    /// Commits until the window's presenter holds no terminal's new size for its frame (at most 2 s).
    static func landDrawnFrames(_ rig: Rig) async {
        let presenter = TerminalFramePresenter.forWindow(rig.window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            await TerminalKeyResizeFrameTests.commit()
        } while ContinuousClock.now < deadline && terminals(in: rig.root).contains { presenter.isWaiting($0) }
    }

    /// The terminal surfaces under `view`, shown or parked.
    static func terminals(in view: NSView) -> [TerminalSurfaceView] {
        view.subviews.flatMap { ($0 as? TerminalSurfaceView).map { [$0] } ?? terminals(in: $0) }
    }

    // MARK: Note 2: the surface stays fixed at the pane edge that does not move

    /// One press on each side of each axis. p2 grows to the left (H: its leading edge moves), p1 grows to the right (L
    /// on p1: the trailing edge moves), p2 grows up (K: its top edge moves), p1 grows down (J on p1: its bottom edge
    /// moves). In every frame each surface keeps its place against the pane edge that does not move, and the host
    /// follows the pane. The surface fills its area, so it is on that edge because it is on every edge; aKeyPressShowsEachSurfaceAtItsPanesSizeAndSendsOneGrid checks the size. This case
    /// guarded the deleted switch-off path and its low-prompt bottom hold (aPromptOnTheLastRowStaysInViewInAPaneAKeyGrowsDown).
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

    // MARK: Note 3: pixels per frame, one grid per press (cmux-ad m6)

    /// One press: in every refresh each terminal's surface has the size its pane shows it at, and it
    /// takes a new size in most of them (its text follows the pane); no grid goes in the key's turn, and each PTY gets at
    /// most one grid per 25 ms window, ending at its final grid (m6 sent the final grid by the first frame).
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressShowsEachSurfaceAtItsPanesSizeAndItsPTYEndsAtItsFinalGrid(direction: LayoutDirection) async throws {
        let vertical = direction == .up || direction == .down
        let rig = Rig(PaneGroundCoversPaneTests.column(vertical ? PaneGroundCoversPaneTests.stack : PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var off: [String] = [], sizes: [PaneID: [CGSize]] = [:]
        var last: [PaneID: CGSize] = [:]
        for pane in panes { last[pane] = try Self.surface(pane, in: rig).frame.size }
        func note(_ label: String) throws {
            off += try Self.offTheirPanes(panes, in: rig, label)
            for pane in panes {
                let size = try Self.surface(pane, in: rig).frame.size
                if size != last[pane] { sizes[pane, default: []].append(size) }
                last[pane] = size
            }
        }
        let reportsBefore = TerminalSurfaceView.gridReports
        let pressed = ContinuousClock.now
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(TerminalSurfaceView.gridReports == reportsBefore, "the key's turn sent \(TerminalSurfaceView.gridReports - reportsBefore) grids")
        await Self.landDrawnFrames(rig)
        try note("the key's turn")
        let frames = try await Self.runRefreshes(rig) { frame in try note("frame \(frame)") }
        try note("after the landing")
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a surface off its pane's size: \(off.prefix(3))")
        let windows = TerminalKeyResizeFrameTests.coalescingWindows(since: pressed)
        #expect(TerminalSurfaceView.gridReports - reportsBefore <= UInt64(panes.count * windows),
                "more grid reports than one per terminal per refresh (\(windows)) for one press")
        for pane in panes {
            let grids = try await Self.grids(pane, rig)
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            #expect(grids.count <= windows && grids.last == final,
                    "\(pane) asked its PTY for \(grids), not at most one grid per refresh (\(windows)) ending at its final grid \(final)")
            #expect((sizes[pane] ?? []).count > 3, "\(pane)'s surface took \(sizes[pane]?.count ?? 0) sizes in a \(frames)-frame spring: its text did not follow its pane")
        }
    }

    /// A held key (three Ctrl-Shift-H presses 4 refreshes apart retarget one spring): in every refresh each terminal's
    /// surface has the size its pane shows it at; each terminal's PTY gets at most one grid per read of its grids (each
    /// read ends the coalescer's window) and per 25 ms window (cmux-ad m18: m6 sent each press's final grid by its first
    /// frame), and the last is the final grid.
    @Test
    func aHeldKeyShowsEachSurfaceAtItsPanesSizeAndItsPTYEndsAtTheFinalGrid() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var off: [String] = [], grids: [PaneID: [TerminalGridSize]] = [:]
        var frames = 0
        let pressed = ContinuousClock.now
        for press in 1...3 {
            #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root), "press \(press) moved nothing")
            rig.root.syncWithModel()
            // The press's first frame is its own (S1B): its grid goes there.
            if await Self.refresh(rig) { frames += 1 }
            off += try Self.offTheirPanes(panes, in: rig, "press \(press)")
            for pane in panes { grids[pane, default: []] += try await Self.grids(pane, rig) }
            for _ in 1...3 {
                guard await Self.refresh(rig) else { break }
                frames += 1
                off += try Self.offTheirPanes(panes, in: rig, "frame \(frames)")
            }
        }
        try await Self.runRefreshes(rig) { _ in
            frames += 1
            off += try Self.offTheirPanes(panes, in: rig, "frame \(frames)")
        }
        off += try Self.offTheirPanes(panes, in: rig, "after the landing")
        #expect(frames > 12, "the presses did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a surface off its pane's size: \(off.prefix(3))")
        for pane in panes {
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            let sent = (grids[pane] ?? []) + (try await Self.grids(pane, rig))
            // One per read at each press (3) and one per window, the landing's flush included.
            let most = 3 + TerminalKeyResizeFrameTests.coalescingWindows(since: pressed)
            #expect(sent.count <= most && sent.last == final,
                    "\(pane) asked its PTY for \(sent) over 3 presses and the landing (final \(final), at most \(most))")
        }
    }

    /// A press and its reverse in one key hold (Ctrl-Shift-H, then L 4 frames later, before the first lands): the panes
    /// rest where they began. Each terminal's surface has its pane's size in every refresh and rests at its start size; its
    /// PTY gets at most one grid per read of its grids and per 25 ms window (m18: the view's grid coalesced; m6 sent each
    /// press's final grid by its first frame), and ends at its start grid.
    @Test
    func aPressAndItsReverseInOneHoldEndsAtTheStartGrid() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var start: [PaneID: (size: CGSize, grid: TerminalGridSize?)] = [:]
        for pane in panes {
            let surface = try Self.surface(pane, in: rig)
            start[pane] = (surface.frame.size, surface.fittedGrid)
        }
        var off: [String] = []
        let pressed = ContinuousClock.now
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(await Self.refresh(rig), "the first press did not spring")
        off += try Self.offTheirPanes(panes, in: rig, "frame 1")
        var atPress: [PaneID: [TerminalGridSize]] = [:]
        for pane in panes { atPress[pane] = try await Self.grids(pane, rig) }
        for frame in 2...4 {
            #expect(await Self.refresh(rig), "the first press landed after \(frame) frames")
            off += try Self.offTheirPanes(panes, in: rig, "frame \(frame)")
        }
        #expect(PaneResize.press("p2", .right, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        #expect(await Self.refresh(rig), "the reverse press did not spring")
        off += try Self.offTheirPanes(panes, in: rig, "the reverse press's first frame")
        var atReverse: [PaneID: [TerminalGridSize]] = [:]
        for pane in panes { atReverse[pane] = try await Self.grids(pane, rig) }
        let frames = try await Self.runRefreshes(rig) { frame in off += try Self.offTheirPanes(panes, in: rig, "reverse frame \(frame)") }
        #expect(frames > 3, "the reverse press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a surface off its pane's size: \(off.prefix(3))")
        for pane in panes {
            let was = try #require(start[pane]), surface = try Self.surface(pane, in: rig)
            let startGrid = try #require(was.grid, "SETUP: \(pane) fits no grid at rest")
            let landing = try await Self.grids(pane, rig)
            let sent = (atPress[pane] ?? []) + (atReverse[pane] ?? []) + landing
            // One per read at each press (2) and one per window, the landing's flush included.
            let most = 2 + TerminalKeyResizeFrameTests.coalescingWindows(since: pressed)
            #expect(sent.count <= most && (sent.last ?? startGrid) == startGrid,
                    "\(pane): the presses sent \(atPress[pane] ?? []), \(atReverse[pane] ?? []) and \(landing): its PTY does not end at the start grid \(startGrid)")
            #expect(surface.frame.size == was.size, "\(pane)'s surface rests at \(surface.frame.size), not its start size \(was.size)")
        }
    }

    /// Whether `view`'s cursor is in the lower half of a normal screen (the low prompt a pane growing down once held on its
    /// bottom edge).
    static func promptIsLow(_ view: TerminalSurfaceView) -> Bool {
        guard let surface = view.surface else { return false }
        var metrics = ghostty_surface_grid_metrics_s()
        return ghostty_surface_grid_metrics(surface, &metrics) && metrics.cursor_in_viewport && !metrics.alternate_screen
            && metrics.rows > 0 && Int(metrics.cursor_row) * 2 >= Int(metrics.rows)
    }

    /// The surfaces of `panes` whose size is not the one their pane shows them at now (their host's area,
    /// ``TerminalHostView/surfaceSize(forHostSize:)``), labeled with `label`, with what the window's presenter holds for
    /// each ("request": a size waits for its drawn frame) and the size asked of Ghostty and not shown yet.
    static func offTheirPanes(_ panes: [PaneID], in rig: Rig, _ label: String) throws -> [String] {
        let presenter = TerminalFramePresenter.forWindow(rig.window)
        return try panes.compactMap { pane in
            let surface = try Self.surface(pane, in: rig)
            let host = try #require(rig.provider.sessions[pane]?.session.view)
            let shown = host.surfaceSize(forHostSize: host.bounds.size)
            guard surface.frame.size != shown else { return nil }
            let waits = surface.frameOwnership.inFlight.map { "\($0)" } ?? "none"
            return "\(label): \(pane)'s surface \(surface.frame.size) in a \(shown) area (presenter \(presenter.debugState(of: surface)), in flight \(waits))"
        }
    }

    /// Review of #35470 (F3): a terminal tab parked when a key press began (another tab showed) and shown again during the
    /// spring follows its pane from the frame it shows: it is unhidden before its area hands it the hold (in the next
    /// layout pass), and `restAt` held its surface at the final size then, a size its pane did not have yet. With the
    /// switch off (T5) it took at most one new size from the frame it showed; cmux-ad m18 deleted that hold, so it
    /// has its area's size in every frame and lands at it.
    @Test
    func aParkedTerminalShownDuringAKeyHoldFollowsFromItsFirstFrame() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let pane = try #require(rig.root.context.hosts["p2"]?.content as? PaneContentView)
        let shown = try #require(rig.provider.sessions["p2"]?.session)
        let io = GridRecordingTerminalIO()
        let parked = TerminalSession(io: io)
        defer {
            parked.close()
            io.finish()
        }
        // The second tab shows once, then the first one again: the second stays parked (hidden) in the pane.
        _ = pane.show(parked.view)
        rig.root.layoutSubtreeIfNeeded()
        _ = pane.show(shown.view)
        rig.root.layoutSubtreeIfNeeded()
        try #require(parked.view.isHidden && parked.view.superview != nil, "the second tab was not parked in the pane")
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...6 { _ = rig.frame() }
        // The tab switch back to the parked terminal, mid-spring.
        _ = pane.show(parked.view)
        rig.root.layoutSubtreeIfNeeded()
        var off: [String] = []
        func check(_ label: String) {
            let host = parked.view, size = parked.surfaceView.frame.size
            let area = host.surfaceSize(forHostSize: host.bounds.size)
            if size != area { off.append("\(label): its surface \(size) in a \(area) area") }
        }
        check("the switch's frame")
        let frames = try Self.run(rig) { frame in check("frame \(frame)") }
        #expect(frames > 3, "the spring landed before the switch (\(frames) frames left)")
        #expect(off.isEmpty, "the shown terminal did not follow its pane: \(off.prefix(3))")
        let host = parked.view
        #expect(parked.surfaceView.frame.size == host.surfaceSize(forHostSize: host.bounds.size), "the shown terminal did not land at its area's size")
    }

    /// Review of #35470 (F2): a pane that a key press grows down keeps a prompt on its last row in view, as S3 did (and as
    /// a split or a close does, TerminalPaneMotionFinalGridTests): the PTY gets the final, taller grid at the press, and a
    /// surface at the pane's size in each frame showed that grid's top rows, cut off at the bottom, so the prompt was out
    /// of view for the whole spring.
    /// - cmux-ad m14 replaced S3's bottom hold with the switch on (F2: the surface was taller than its pane and its top
    ///   rows were cut), and m18 replaced it with the switch off too (m19 deleted the switch): the surface has its pane's size in
    ///   every frame and holds nothing; it draws the grid that size fits, and the reflow keeps the prompt in view
    ///   (TerminalKeyResizeFrameTests checks what it draws, in a window that draws).
    @Test
    func aPromptOnTheLastRowStaysInViewInAPaneAKeyGrowsDown() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.stack), focused: "p1")
        defer { rig.close() }
        let terminal = try #require(rig.provider.sessions["p1"])
        // A device attributes query after the prompt: its reply says the lines before it were parsed.
        terminal.io.send(.output(Data((String(repeating: "line\r\n", count: 200) + "$ \u{1b}[c").utf8)))
        await terminal.io.nextWrite()
        #expect(PaneResize.press("p1", .down, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var taller = 0, cut: [String] = [], unfollowed: [String] = []
        let frames = try Self.run(rig) { frame in
            unfollowed += try Self.offTheirPanes(["p1"], in: rig, "frame \(frame)")
            if terminal.session.view.surfaceHold != nil { unfollowed.append("frame \(frame): p1's surface keeps a hold") }
            let clip: NSView = terminal.session.view
            let surface = terminal.session.surfaceView.convert(terminal.session.surfaceView.bounds, to: clip)
            let visible = clip.bounds
            guard surface.height > visible.height + 1 else { return }
            taller += 1
            let off = clip.isFlipped ? surface.maxY - visible.maxY : visible.minY - surface.minY
            if abs(off) >= 1 { cut.append("frame \(frame): \(off) pt of the terminal's bottom is cut off") }
        }
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(taller == 0, "the terminal was taller than its pane on \(taller) of \(frames) frames: a hold cut its top rows: \(cut.prefix(3))")
        #expect(unfollowed.isEmpty, "\(unfollowed.count) frames showed p1's surface off its pane's size or holding: \(unfollowed.prefix(3))")
    }

    /// Review of #35470 at c4d6c936c92 (H1 a): in a 2x2 grid, Ctrl-Shift-H on p4
    /// (bottom right) moves its left edge, then Ctrl-Shift-K on p4 before the landing grows it up with its prompt in the
    /// lower half. `restAt` held its surface on the bottom edge then (F2), and that hold kept the final width on the
    /// hold's trailing edge: the moving left edge cut off the start of every line (#35914 gave the hold the area's width).
    /// cmux-ad m14 replaced the hold: in every frame p4's surface has its area's frame (its leading edge, width, top and
    /// height) and holds nothing.
    @Test func aLowPromptPressOnTheOtherAxisKeepsTheSurfaceOnItsArea() async throws {
        let grid: SplitNode = .split("x", axis: .horizontal, ratio: 0.5,
                                     a: .split("l", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p3")),
                                     b: .split("r", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p4")))
        let rig = Rig(PaneGroundCoversPaneTests.column(grid), focused: "p4")
        defer { rig.close() }
        let terminal = try #require(rig.provider.sessions["p4"])
        // A device attributes query after the prompt: its reply says the lines before it were parsed.
        terminal.io.send(.output(Data((String(repeating: "line\r\n", count: 200) + "$ \u{1b}[c").utf8)))
        await terminal.io.nextWrite()
        try #require(Self.promptIsLow(terminal.session.surfaceView), "SETUP: p4's prompt is not in the lower half: the low-prompt case did not happen")
        #expect(PaneResize.press("p4", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        for _ in 1...4 { _ = rig.frame() }
        #expect(PaneResize.press("p4", .up, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        var off: [String] = []
        func check(_ label: String) {
            let host = terminal.session.view, surface = terminal.session.surfaceView.frame
            let area = host.surfaceSize(forHostSize: host.bounds.size)
            if host.surfaceHold != nil { off.append("\(label): p4's surface keeps a hold") }
            if abs(surface.minX - host.bounds.minX) > 0.5 || abs(surface.width - area.width) > 0.5
                || abs(surface.maxY - host.bounds.maxY) > 0.5 || abs(surface.height - area.height) > 0.5 {
                off.append("\(label): p4's surface \(surface), its area x \(host.bounds.minX) top \(host.bounds.maxY) size \(area)")
            }
        }
        let frames = try Self.run(rig) { frame in check("frame \(frame)") }
        check("after the landing")
        #expect(frames > 3, "the presses did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed p4's surface off its area or holding: \(off.prefix(3))")
    }

    /// Review of #35470 at c4d6c936c92 (H1 b): Ctrl-Shift-J on p1 twice (its prompt
    /// in the lower half), then Ctrl-Shift-K before the landing. The rest is still taller than at the start of the hold,
    /// so the K press kept a bottom hold at its final size, shorter than p1's area mid-spring: a band of the terminal's
    /// ground showed at the top of the pane until the landing (#35914 gave such a hold the area's frame). cmux-ad m14
    /// replaced the hold: in every frame p1's surface has its area's height, on its top edge, and holds nothing.
    @Test func aLowPromptGrowDownTwiceThenUpKeepsTheSurfaceOnItsArea() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.stack), focused: "p1")
        defer { rig.close() }
        let terminal = try #require(rig.provider.sessions["p1"])
        terminal.io.send(.output(Data((String(repeating: "line\r\n", count: 200) + "$ \u{1b}[c").utf8)))
        await terminal.io.nextWrite()
        try #require(Self.promptIsLow(terminal.session.surfaceView), "SETUP: p1's prompt is not in the lower half: the low-prompt case did not happen")
        for press: LayoutDirection in [.down, .down] {
            #expect(PaneResize.press("p1", press, model: rig.model, view: rig.root))
            rig.root.syncWithModel()
            for _ in 1...2 { _ = rig.frame() }
        }
        #expect(PaneResize.press("p1", .up, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        var off: [String] = []
        func check(_ label: String) {
            let host = terminal.session.view, surface = terminal.session.surfaceView.frame
            let area = host.surfaceSize(forHostSize: host.bounds.size)
            if host.surfaceHold != nil { off.append("\(label): p1's surface keeps a hold") }
            if abs(surface.height - area.height) > 0.5 || abs(surface.maxY - host.bounds.maxY) > 0.5 {
                off.append("\(label): p1's surface \(surface.height) pt tall, top \(surface.maxY), in a \(area.height) pt area, top \(host.bounds.maxY)")
            }
        }
        check("the K press's first frame")
        let frames = try Self.run(rig) { frame in check("frame \(frame)") }
        #expect(frames > 3, "the presses did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed p1's surface off its area or holding: \(off.prefix(3))")
    }

    /// Review of #35470 at 447f784c3cf (G1 a): Ctrl-Shift-J grows p1 down with its prompt in the lower half;
    /// Ctrl-Shift-K before the landing reverses it.
    /// The J press held p1's surface at its final size on the bottom edge (F2) and the bottom hold stayed until the
    /// landing, so the shrinking pane showed the text with its top step cut off over an empty band. cmux-ad m14 (switch on)
    /// and m18 (switch off too; m19 deleted the switch) replaced that hold: the J press holds nothing, and each surface has its
    /// pane's size in every frame of both presses.
    @Test
    func aReversePressAfterALowPromptGrowsDownFollowsItsPane() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.stack), focused: "p1")
        defer { rig.close() }
        let terminal = try #require(rig.provider.sessions["p1"])
        // A device attributes query after the prompt: its reply says the lines before it were parsed.
        terminal.io.send(.output(Data((String(repeating: "line\r\n", count: 200) + "$ \u{1b}[c").utf8)))
        await terminal.io.nextWrite()
        let startSize = terminal.session.surfaceView.frame.size
        #expect(PaneResize.press("p1", .down, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        var held = 0
        for _ in 1...4 where rig.frame() {
            let surface = terminal.session.surfaceView.frame.size, host = terminal.session.view
            if surface.height > host.surfaceSize(forHostSize: host.bounds.size).height + 1 { held += 1 }
        }
        #expect(held == 0, "the grow-down press held p1's surface taller than its pane on \(held) frames")
        #expect(PaneResize.press("p1", .up, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        var off: [String] = []
        let frames = try Self.run(rig) { frame in off += try Self.offTheirPanes(["p1", "p2"], in: rig, "reverse frame \(frame)") }
        off += try Self.offTheirPanes(["p1", "p2"], in: rig, "after the landing")
        #expect(frames > 3, "the reverse press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames showed a surface off its pane's size after the reverse press: \(off.prefix(3))")
        #expect(terminal.session.surfaceView.frame.size == startSize, "p1's surface rests at \(terminal.session.surfaceView.frame.size), not its start size \(startSize)")
    }

    /// Review of #35470 at 447f784c3cf (G1 b): a parked terminal tab shown again during a key hold is unhidden before its
    /// area hands it the follow (in the area's next layout pass), so its surface joined the spring with the OFF path's hold
    /// at the press's final size; a second press before the landing left that hold, and the landing's release sized the
    /// surface from it: grid1, grid2, grid1, grid2 for two presses. cmux-ad m18 replaces "one grid per press" with the
    /// coalescer's rule: the PTY gets at most one grid per 25 ms window from the press to the landing (plus the landing's
    /// flush), the last is the final grid, and none goes after it. The join sends no final grid of its own outside the
    /// coalescer: it joins its area's key hold and follows it (`restAt`). (A tab added new mid-hold hears the follow in
    /// `didAddSubview`, before its surface joins: no hold.) (T5)
    @Test
    func aTerminalThatJoinsAKeyHoldGetsOneGridPerPressThroughASecondPress() async throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let pane = try #require(rig.root.context.hosts["p2"]?.content as? PaneContentView)
        let shown = try #require(rig.provider.sessions["p2"]?.session)
        let io = GridRecordingTerminalIO()
        let parked = TerminalSession(io: io)
        defer {
            parked.close()
            io.finish()
        }
        // No flush here: a grid in the coalescer's window goes when the window ends (or at the landing).
        func marker() async -> [TerminalGridSize] {
            parked.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        // The second tab shows once, then the first one again: the second stays parked (hidden) in the pane.
        _ = pane.show(parked.view)
        rig.root.layoutSubtreeIfNeeded()
        _ = pane.show(shown.view)
        rig.root.layoutSubtreeIfNeeded()
        try #require(parked.view.isHidden && parked.view.superview != nil, "the second tab was not parked in the pane")
        _ = await marker()
        let pressed = ContinuousClock.now
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...4 { _ = await Self.refresh(rig) }
        // The tab switch back to the parked terminal, mid-spring.
        _ = pane.show(parked.view)
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...2 { _ = await Self.refresh(rig) }
        let atJoin = await marker()
        // A second press before the landing.
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        _ = await Self.refresh(rig)
        let atSecond = await marker()
        let frames = try await Self.runRefreshes(rig)
        let presenter = TerminalFramePresenter.forWindow(rig.window)
        let atLanding = "presenter \(presenter.debugState(of: parked.surfaceView)), in flight \(parked.surfaceView.frameOwnership.inFlight.map { "\($0)" } ?? "none"), grid at landing \(String(describing: parked.surfaceView.fittedGrid))"
        let afterLanding = await marker()
        let final = try #require(parked.surfaceView.fittedGrid)
        #expect(frames > 3, "the second press did not spring (\(frames) frames)")
        let sent = atJoin + atSecond + afterLanding
        let windows = TerminalKeyResizeFrameTests.coalescingWindows(since: pressed)
        #expect(sent.count <= windows,
                "the PTY got \(sent.count) grids, more than one per refresh (\(windows)): join \(atJoin), second press \(atSecond), landing \(afterLanding)")
        #expect(sent.last == final, "the PTY got \(sent), not ending at the final grid \(final) (\(atLanding))")
        let afterFinal = sent.drop(while: { $0 != final }).dropFirst()
        #expect(afterFinal.isEmpty, "the PTY got \(Array(afterFinal)) after the final grid \(final): \(sent)")
    }

    /// The grids `pane`'s terminal asked its PTY for since the last call (a focus report after them is the marker).
    static func grids(_ pane: PaneID, _ rig: Rig) async throws -> [TerminalGridSize] {
        let session = try #require(rig.provider.sessions[pane])
        // cmux-ad m18: a grid in the coalescer's 25 ms window counts as asked for (it goes when the window ends).
        session.session.surfaceView.gridReports.flush()
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
        let atShow = joining.surfaceView.fittedGrid
        var off: [String] = [], atFirstFrame: TerminalGridSize?
        let frames = try Self.run(rig) { frame in
            let host = joining.view, area = try #require(host.superview)
            if host.frame.size != area.bounds.size { off.append("frame \(frame): the joining host \(host.frame.size) in \(area.bounds.size)") }
            if frame == 1 { atFirstFrame = joining.surfaceView.fittedGrid }
        }
        #expect(frames > 3, "the spring landed before the switch (\(frames) frames left)")
        #expect(off.isEmpty, "the joining terminal's host did not follow its pane: \(off.prefix(3))")
        let host = joining.view
        #expect(joining.surfaceView.frame.size == host.surfaceSize(forHostSize: host.bounds.size),
                "the joining surface rests at \(joining.surfaceView.frame.size) in a \(host.bounds.size) host")
        joining.surfaceView.bridge.takeUnretainedValue().input.focusGained()
        let grids = await io.gridsUntilMarker()
        let final = try #require(joining.surfaceView.fittedGrid)
        // RESIZE P0 7: the grid of the first landed frame (the join's, or the next frame's) goes at once; these frames run in
        // one turn, so no refresh ends a window and the rest go as the final grid. Exact: any other first grid fails
        // (RESIZE P0 8, review of 28a640183a7).
        let allowed = [[final]] + [atShow, atFirstFrame].compactMap { $0 }.filter { $0 != final }.map { [$0, final] }
        #expect(allowed.contains(grids),
                "the joining terminal asked its PTY for \(grids), not [the join's \(String(describing: atShow)) or its first frame's grid \(String(describing: atFirstFrame)),] then its final grid \(final)")
    }
}
