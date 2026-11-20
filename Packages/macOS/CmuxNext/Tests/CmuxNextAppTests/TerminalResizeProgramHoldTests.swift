import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// RESIZE P0 12 (Lawrence m55, "terminals: zero lag"): a key resize shows a terminal's new size only with the frame
/// Ghostty drew after the program's redraw at that size's grid, never with the program's last picture clipped or
/// padded at it (a frame of the size only, `GHOSTTY_HOST_FRAME_READY`), unless the program does not redraw within the
/// hold's bound (``TerminalFramePresenter/resizeHoldTicks``).
///
/// Before: the pass presented whatever Ghostty drew for the new size. The grid goes to the program with the size asked
/// of Ghostty (#38125), but the program's output is parsed about 3.5 ms after the send and the pass often came first:
/// cmux21 (macOS 26, 1x 120 Hz) px-keys-held-2-s1r showed the program's old rings cut at the divider in 22-36 frames per
/// film after #38125.
///
/// p1 | p2, each a full-screen program (the alternate screen, a ring on its edges) that redraws its ring at each grid
/// its PTY gets, 3 ms after the send (``AnnouncingTerminalIO``). A held key: Ctrl-Shift-H, H, L on p2 two frames apart,
/// the last to its landing; and a divider drag. Each frame waits (at most 2 s) for its sizes to show.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalResizeProgramHoldTests {
    @Test func aKeySpringShowsEachNewGridOnlyWithTheProgramsRedrawAtIt() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        let presents = Presents(screen)
        defer { presents.stop() }

        var steps = 0
        let presses: [LayoutDirection] = [.left, .left, .right]
        for (index, direction) in presses.enumerated() {
            try #require(PaneResize.press("p2", direction, model: screen.model, view: screen.root), "Ctrl-Shift-\(direction) on p2 moved nothing")
            let last = index == presses.count - 1
            var moving = true, stepped = 0
            while moving, stepped < (last ? 240 : 2) {
                moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
                await Self.waitForShownSizes(screen)
                stepped += 1
            }
            try #require(last || moving, "press \(index + 1) landed before the next press")
            steps += stepped
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(steps >= 4, "the presses' spring ran \(steps) frames: no spring ran")
        try presents.check("key spring, \(steps) frames")
    }

    /// The same rule for a person's divider drag (RESIZE P0 12): its grid goes with the size asked of Ghostty, and the size
    /// shows only with the program's redraw at it. Before, the grid went once the size showed (cmux-ad m29), so every drag
    /// frame showed the program's previous picture clipped or padded at the new size. The split's divider moves 6 pt left
    /// per frame for 20 frames, then the release and its landing.
    @Test func aDividerDragShowsEachNewGridOnlyWithTheProgramsRedrawAtIt() async throws {
        let screen = try await Self.ringScreen()
        defer { screen.close() }
        let presents = Presents(screen)
        defer { presents.stop() }
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 20
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await Self.waitForShownSizes(screen)
        }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving || steps < 6, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            await Self.waitForShownSizes(screen)
            steps += 1
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try presents.check("divider drag, \(moves) moves")
    }

    /// One bound per request (RESIZE P0 15, design item 2): a full-screen program that did not redraw within one press's
    /// bound is held again at the next press. Before, the first bound present set a latch (`programMissedHold`) that only
    /// a frame the program drew for a HELD request cleared, so from then on no size of that terminal waited and every
    /// frame showed the program's last picture clipped or padded (#38206 at 340d74d5967: the hold was off for the rest of
    /// the session after one slow redraw).
    /// p1 | p2 full-screen programs; press 1 (Ctrl-Shift-H on p2) while they print nothing, to its landing (the sizes show
    /// at the bound); then they redraw at each grid again, and press 2 (Ctrl-Shift-L) must show each new grid only with
    /// the program's redraw at it.
    @Test func aProgramThatMissedOneBoundIsHeldAgainAtTheNextPress() async throws {
        let program = RingProgram(redraws: false)
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        let presenter = TerminalFramePresenter.forWindow(screen.window)

        let before = presenter.stats.boundPresents
        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "Ctrl-Shift-H on p2 moved nothing")
        try await Self.stepToLanding(screen)
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(presenter.stats.boundPresents > before,
                     "SETUP: press 1 showed no size at the hold's bound (bound presents \(before) -> \(presenter.stats.boundPresents)): the quiet program was not held")

        // The program is slow, not dead: as a real one does after its SIGWINCH, it redraws late, once, at its newest grid.
        // Without this its picture would stay at the grid before press 1, and press 2's first refresh (a 2 px step at
        // the same grid, so no new grid to answer) would show that stale picture whatever the hold does.
        program.redraws = true
        for (io, session) in zip(screen.ios, screen.sessions) {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            io.send(.output(program.redraw(cols: grid.columns, rows: grid.rows)))
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        let presents = Presents(screen)
        defer { presents.stop() }
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        try await Self.stepToLanding(screen)
        await TerminalKeyResizeFrameTests.settle(screen)
        // The rule itself, not only its pictures (review of 17154838e7b P2 1): press 2's first new size of each terminal
        // waits for the program's redraw. With the latch, it did not (hold refreshes 0), and the fast redraw hid it.
        let unheld = presents.firstHoldTicks.filter { $0.value != TerminalFramePresenter.resizeHoldTicks }
        #expect(!presents.firstHoldTicks.isEmpty && unheld.isEmpty,
                "press 2's first new sizes waited \(presents.firstHoldTicks.sorted { $0.key < $1.key }) refreshes for the program's redraw, not \(TerminalFramePresenter.resizeHoldTicks): a missed bound turned the hold off")
        try presents.check("the press after a missed bound")
    }

    /// Held geometry (RESIZE P0 15, design item 3; m55 lead default): while a full-screen program's redraw is due, the
    /// pane moves in the press's first frame and the surface keeps the program's last frame at its OLD size, anchored
    /// top-left in the pane, unscaled (its layer shows its frame pixel for pixel); the strip a grow opens beside it has the
    /// program's background colour (OSC 11), not the theme's. The host clips the old frame at its own edge on a shrink,
    /// so it never draws over the neighbour. p2's program set its background with OSC 11 and does not redraw; Ctrl-Shift-L
    /// grows p2.
    @Test func aHeldFrameKeepsItsOldSizeTopLeftBesideTheProgramsBackground() async throws {
        let program = RingProgram(redraws: false, background: (0x20, 0x40, 0x60))
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        let session = screen.sessions[1]
        let view = session.surfaceView
        let host = try #require(view.superview as? TerminalHostView, "SETUP: p2's surface has no host")
        let painted = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in session.model.backgroundOverride != nil }
        try #require(painted, "SETUP: p2's OSC 11 set no background")
        try #require(host.layer?.masksToBounds == true, "the host does not clip its surface: a held frame larger than its pane draws over the neighbour")
        let oldSize = view.bounds.size, oldHost = host.bounds.size

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        var held: [String] = [], checked = 0
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
            steps += 1
            guard view.frameOwnership.inFlight != nil, let wanted = view.frameOwnership.wanted, wanted.width > view.frame.width
            else { continue }
            checked += 1
            let frame = view.frame
            if frame.minX != wanted.minX || frame.maxY != wanted.maxY { held.append("frame \(steps): \(frame) not top-left in \(wanted)") }
            if let layer = view.layer, let shown = view.presentedFrame {
                let scale = layer.contentsScale
                if Int((layer.bounds.width * scale).rounded()) != shown.width || Int((layer.bounds.height * scale).rounded()) != shown.height {
                    held.append("frame \(steps): layer \(layer.bounds.size) scales a \(shown.width)x\(shown.height) frame")
                }
            }
            if host.bounds.size == oldHost { held.append("frame \(steps): the pane waited with the surface (host \(oldHost))") }
            if !Self.sameColor(host.layer?.backgroundColor, program.background) {
                held.append("frame \(steps): the grow strip is \(String(describing: host.layer?.backgroundColor)), not the program's background")
            }
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(steps >= 4, "the press's spring ran \(steps) frames: no spring ran")
        try #require(checked >= 1, "no frame held p2 at its old size \(oldSize) while its pane grew (the quiet program was not held)")
        #expect(held.isEmpty, "\(held.count) held frames broke the held geometry: \(held.prefix(6))")
    }

    /// RESIZE P0 20 (films px-keys-held-2-s1r-claude under Reduce Motion, cmux21 1x 120 Hz, strip band-233644-rm-br): a
    /// Reduce Motion key press snaps, and its snap shows at the next frame tick (RESIZE P0 13, KEY SNAP GRID). When Claude
    /// Code had not redrawn at the new grid by that tick, the tick showed the divider at its new place and the grown pane
    /// filled, but the program's picture at its OLD width for a refresh (the presenter held the surface for the program's
    /// redraw while the pane took its new size): its rules and status line ended short of the new edge. A key press's
    /// grid goes with its size (RESIZE P0 11), so the snap waits for that redraw as the presenter does: the pane and its
    /// terminal show the new size together, with the program's picture at the new grid (at most
    /// ``TerminalFramePresenter/resizeHoldTicks`` refreshes, then the size shows anyway).
    /// p1 | p2 full-screen programs; Reduce Motion on; p2's program is busy at the press and redraws a refresh late.
    /// Ctrl-Shift-L grows p2.
    @Test func aReduceMotionGrowShowsTheNewPaneSizeOnlyWithTheProgramsRedrawAtIt() async throws {
        let program = RingProgram(redraws: false)
        let screen = try await Self.ringScreen(program)
        defer { screen.close() }
        screen.root.context.reduceMotionOverride = true
        let session = screen.sessions[1], view = session.surfaceView, host = session.view
        let oldHost = host.bounds.size
        let presents = Presents(screen)
        defer { presents.stop() }

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the key's turn, its presenter pass and its commit
        // Ghostty draws p2's new size before the tick; the busy program has not redrawn at its grid.
        let drawn = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in
            view.frameOwnership.ahead != nil && view.hostFrame(present: false) == GHOSTTY_HOST_FRAME_READY
        }
        try #require(drawn, "SETUP: Ghostty drew no frame of p2's new size before the tick (state \(view.hostFrame(present: false).rawValue))")

        var torn: [String] = []
        func record(_ frame: Int) {
            let area = host.surfaceSize(forHostSize: host.bounds.size), shown = view.bounds.size
            let scale = view.layer?.contentsScale ?? 2
            guard host.bounds.width > oldHost.width,
                  abs(area.width - shown.width) * scale > 1 || abs(area.height - shown.height) * scale > 1 else { return }
            torn.append("frame \(frame): pane \(TerminalKeyResizeFrameTests.text(host.bounds.size)), terminal \(TerminalKeyResizeFrameTests.text(shown))")
        }
        _ = await TerminalKeyResizeFrameTests.stepFrame(screen) // the tick that may show the snap
        record(1)
        // The program redraws at the grid its PTY got, a refresh late.
        let grid = try #require(screen.ios[1].resizes.last, "SETUP: p2's PTY got no grid")
        screen.ios[1].send(.output(Self.ring(cols: grid.columns, rows: grid.rows)))
        let redrawn = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in
            view.hostFrame(present: false) == GHOSTTY_HOST_FRAME_READY_PROGRAM || host.bounds.width > oldHost.width
        }
        try #require(redrawn, "SETUP: Ghostty drew no frame after the program's redraw")
        for frame in 2...8 {
            _ = await TerminalKeyResizeFrameTests.stepFrame(screen)
            record(frame)
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(host.bounds.width > oldHost.width, "SETUP: Ctrl-Shift-L did not grow p2 (\(oldHost) -> \(host.bounds.size))")

        #expect(torn.isEmpty, "\(torn.count) frames showed p2's pane at its new size with the program's picture at the old size: \(torn)")
        // p2's only (RESIZE P0 21): p1's program is busy too and never redraws, so p1's size-only frame at the bound is
        // the rule, not a miss.
        let p2SizeOnly = presents.sizeOnly.filter { $0.hasPrefix("p2:") }
        #expect(p2SizeOnly.isEmpty,
                "\(p2SizeOnly.count) frames showed p2's new size with the program's last picture, not its redraw at the new grid: \(p2SizeOnly)")
    }

    /// RESIZE P0 21 (films px-keys-held-2-s1r-claude under Reduce Motion, cmux21 1x 120 Hz, #38206 head 3ddf97f3b02:
    /// claude RM clip 21-33 vs v3 13-15; trace 011256 samples 406-408 and 413-415). The film's shrink presses are real HID
    /// key events, and the main run loop handled such a key and the next display tick in one wake, with no presenter pass
    /// between them. That tick found the size drawn ahead not yet sent to Ghostty (it goes in the pass), so the snap did
    /// not wait for it: the panes took their new sizes, and each terminal's placement asked for its size only then, with a
    /// hold for its program's redraw. The presenter kept the old width in the new pane for up to
    /// ``TerminalFramePresenter/resizeHoldTicks`` refreshes. The Chromium model: no frame shows a pane at its new size with
    /// its terminal at the old one. The snap waits for its terminals (bounded); the commit that shows it shows each
    /// terminal at its new size, with the program's redraw or, at the bound, the size only.
    /// p1 | p2 full-screen programs, busy (they print nothing after a resize); Reduce Motion on; Ctrl-Shift-H on p2 twice
    /// (p2 shrinks, p1 grows), each press's first frame tick in the key's own run loop turn, then a refresh of time per tick.
    @Test func aReduceMotionPressTickedInTheKeysOwnTurnNeverShowsAPaneWithItsTerminalAtTheOldSize() async throws {
        let screen = try await Self.ringScreen(RingProgram(redraws: false))
        defer { screen.close() }
        screen.root.context.reduceMotionOverride = true
        var torn: [String] = [], runs: [String: Int] = [:], longest = 0
        for press in 1...2 {
            let before = screen.sessions.map { $0.view.bounds.size }
            try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "press \(press): Ctrl-Shift-H on p2 moved nothing")
            for tick in 1...8 {
                // Tick 1 runs in the key's own turn, before the presenter's pass (a HID key and a display tick in one wake).
                _ = screen.root.advanceFrame(1.0 / 120)
                screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
                await TerminalKeyResizeFrameTests.refreshOfTime()
                for (index, session) in screen.sessions.enumerated() {
                    let host = session.view, view = session.surfaceView, name = "p\(index + 1)"
                    let area = host.surfaceSize(forHostSize: host.bounds.size), shown = view.bounds.size
                    let scale = view.layer?.contentsScale ?? 2
                    let differs = abs(area.width - shown.width) * scale > 1 || abs(area.height - shown.height) * scale > 1
                    guard host.bounds.size != before[index], differs else {
                        runs[name] = 0
                        continue
                    }
                    runs[name, default: 0] += 1
                    longest = max(longest, runs[name] ?? 0)
                    torn.append("press \(press) refresh \(tick): \(name) pane \(TerminalKeyResizeFrameTests.text(host.bounds.size)), terminal \(TerminalKeyResizeFrameTests.text(shown))")
                }
            }
            await TerminalKeyResizeFrameTests.settle(screen)
            let after = screen.sessions.map { $0.view.bounds.size }
            try #require(after[1].width < before[1].width && after[0].width > before[0].width,
                         "SETUP: press \(press) did not shrink p2 and grow p1 (\(before) -> \(after))")
        }
        print("RESIZE P0 21 RM press ticked in its key's turn: torn \(torn.count), longest run \(longest) refreshes: \(torn.prefix(8))")
        #expect(longest <= 1,
                "a pane showed its new size with its terminal at the old size for \(longest) refreshes in a row (\(torn.count) torn): \(torn.prefix(8))")
    }

    /// The bound of that wait (RESIZE P0 20): a Reduce Motion press whose program never redraws still shows its new size
    /// within ``TerminalFramePresenter/resizeHoldTicks`` refreshes, so a busy program never stops the resize.
    @Test func aReduceMotionPressOfAProgramThatDoesNotRedrawShowsAtTheBound() async throws {
        let screen = try await Self.ringScreen(RingProgram(redraws: false))
        defer { screen.close() }
        screen.root.context.reduceMotionOverride = true
        let session = screen.sessions[1], view = session.surfaceView, host = session.view
        let oldHost = host.bounds.size

        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        await TerminalKeyResizeFrameTests.commit() // the key's turn, its presenter pass and its commit
        let drawn = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) { _ in
            view.frameOwnership.ahead != nil && view.hostFrame(present: false) == GHOSTTY_HOST_FRAME_READY
        }
        try #require(drawn, "SETUP: Ghostty drew no frame of p2's new size before the tick")
        var ticks = 0
        while host.bounds.width <= oldHost.width, ticks < 12 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.refreshOfTime()
            ticks += 1
        }
        #expect(host.bounds.width > oldHost.width && ticks <= Int(TerminalFramePresenter.resizeHoldTicks),
                "p2's pane showed its new size after \(ticks) refreshes (width \(oldHost.width) -> \(host.bounds.width)), not within the bound \(TerminalFramePresenter.resizeHoldTicks)")
        await TerminalKeyResizeFrameTests.settle(screen)
        #expect(TerminalKeyResizeFrameTests.showsItsOwnFrame(session), "p2's terminal does not rest at its own frame")
    }

    /// RESIZE P0 23 (P2 of RESIZE P0 22, trace of film 034647): the hold's bound counts from the refresh in which the
    /// program got its grid, not from the size's request. A grid of a refresh that already sent one waits in the
    /// coalescer for the next refresh (``TerminalGridReportCoalescer``); counted from the request, that program had 2 of
    /// the bound's 3 refreshes to redraw before its last picture showed clipped or padded at the new size.
    /// p1 | p2 full-screen programs that print nothing after a resize (each new size shows at the bound). A grid went to
    /// each PTY earlier in the drag's first refresh (a forced report spends that refresh, as a landing's or a held size's
    /// grid does), then the divider moves 30 pt: the drag's grids wait for the next refresh.
    @Test func aGridCoalescedBehindAnEarlierSendGetsTheWholeBoundFromItsOwnSend() async throws {
        let screen = try await Self.ringScreen(RingProgram(redraws: false))
        defer { screen.close() }
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        let owners = screen.sessions.compactMap { $0.io as? AnnouncingTerminalIO }
        try #require(owners.count == screen.sessions.count, "SETUP: a terminal's IO does not record its reports")
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)

        // Per terminal: the refresh its drag grid went in, and the refreshes from it to its first size-only present.
        var waited: [String: (sent: UInt64, refreshes: UInt64)] = [:]
        presenter.presentingHook = { [unowned screen] surface, state in
            guard state == GHOSTTY_HOST_FRAME_READY, surface.programHoldTicks > 0,
                  let index = screen.sessions.firstIndex(where: { $0.surfaceView === surface }),
                  waited["p\(index + 1)"] == nil,
                  let sent = owners[index].reports.withLock({ $0.last?.epoch }) else { return }
            waited["p\(index + 1)"] = (sent, presenter.currentEpoch &- sent)
        }
        defer { presenter.presentingHook = nil }

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        for session in screen.sessions {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            session.surfaceView.gridReports.now(grid)
        }
        let spentIn = presenter.currentEpoch
        view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - 30, y: start.y), []))
        _ = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, in the forced report's turn
        try #require(screen.sessions.allSatisfy { $0.surfaceView.gridReports.isWaiting },
                     "SETUP: the drag's grids went at once (the forced reports did not spend the refresh)")
        await Self.waitForShownSizes(screen)
        presenter.presentingHook = nil
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - 30, y: start.y), []))
        screen.root.syncWithModel()
        await TerminalKeyResizeFrameTests.settle(screen)

        let names = screen.sessions.indices.map { "p\($0 + 1)" }
        try #require(names.allSatisfy { waited[$0] != nil }, "SETUP: a terminal showed no size-only frame at the bound: \(waited)")
        try #require(names.allSatisfy { (waited[$0]?.sent ?? 0) > spentIn },
                     "SETUP: a drag grid went in the forced report's refresh \(spentIn), not the next: \(waited)")
        let short = names.filter { (waited[$0]?.refreshes ?? 0) < TerminalFramePresenter.resizeHoldTicks }
        #expect(short.isEmpty,
                "\(short) showed the size only \(short.map { waited[$0]?.refreshes ?? 0 }) refreshes after the program got its grid, not \(TerminalFramePresenter.resizeHoldTicks): the hold counted from the request")
    }

    /// RESIZE P0 24 (review of #39470, P2): a Reduce Motion press's held snap counted its bound from the snap, not from
    /// the refresh its program got the grid in. When a grid already went in the press's refresh, the press's grid (sent
    /// with its size drawn ahead) waits in the coalescer for the next refresh (``TerminalGridReportCoalescer``), so the
    /// program had 2 of the bound's 3 refreshes to redraw before the snap showed its pane with the program's last picture
    /// at the new size. The presenter's own hold counts from the send (#39470); the snap's wait must too.
    /// p1 | p2 full-screen programs that print nothing after a resize (the snap shows at its bound); Reduce Motion on.
    /// A forced report spends the press's refresh for each terminal, then Ctrl-Shift-L on p2 and the key's pass: the
    /// press's grids wait for the next refresh. Each stepped tick is a refresh of time.
    @Test func aReduceMotionPressWhoseGridWaitedGetsTheWholeBoundFromItsSend() async throws {
        let screen = try await Self.ringScreen(RingProgram(redraws: false))
        defer { screen.close() }
        screen.root.context.reduceMotionOverride = true
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        let owners = screen.sessions.compactMap { $0.io as? AnnouncingTerminalIO }
        try #require(owners.count == screen.sessions.count, "SETUP: a terminal's IO does not record its reports")
        let session = screen.sessions[1], view = session.surfaceView, host = session.view
        let oldHost = host.bounds.size

        // One turn: the forced reports, the press (its snap draws each new size ahead) and the key's pass (the sizes go to
        // Ghostty, their grids to the coalescer, which holds them: this refresh already sent one).
        for session in screen.sessions {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            session.surfaceView.gridReports.now(grid)
        }
        let sentBefore = owners[1].reports.withLock { $0.count }
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        presenter.pass()
        try #require(view.frameOwnership.ahead != nil && view.gridReports.isWaiting,
                     "SETUP: p2's press drew no size ahead, or its grid went at once (ahead \(String(describing: view.frameOwnership.ahead)), waiting \(view.gridReports.isWaiting))")

        // The tick after which p2's PTY got the press's grid, and the tick that showed p2's pane at its new size.
        var sentAfter: Int?, shownAt: Int?
        for tick in 1...8 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            if host.bounds.width > oldHost.width { shownAt = tick }
            if shownAt != nil { break }
            await TerminalKeyResizeFrameTests.refreshOfTime()
            if sentAfter == nil, owners[1].reports.withLock({ $0.count }) > sentBefore { sentAfter = tick }
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        try #require(host.bounds.width > oldHost.width, "SETUP: Ctrl-Shift-L did not grow p2 (\(oldHost) -> \(host.bounds.size))")
        let sent = try #require(sentAfter, "SETUP: p2's PTY got no grid before its snap showed (shown at tick \(String(describing: shownAt)))")
        let shown = try #require(shownAt, "p2's snap did not show within 8 refreshes")
        let refreshes = shown - sent, bound = Int(TerminalFramePresenter.resizeHoldTicks)
        print("RESIZE P0 24 RM snap: grid sent after tick \(sent), snap shown at tick \(shown): \(refreshes) refreshes from the send")
        #expect(refreshes >= bound,
                "p2's snap showed \(refreshes) refreshes after its program got the grid (sent after tick \(sent), shown at tick \(shown)), not \(bound): the snap counted its bound from the press, not the send")
        #expect(refreshes <= bound, "p2's snap waited \(refreshes) refreshes after its program got the grid, more than the bound \(bound)")
    }

    /// Whether `color` is the sRGB colour `rgb` (to 1/255), opaque.
    static func sameColor(_ color: CGColor?, _ rgb: (UInt8, UInt8, UInt8)?) -> Bool {
        guard let rgb, let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB), srgb.alphaComponent == 1 else { return false }
        let parts = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return parts == [Int(rgb.0), Int(rgb.1), Int(rgb.2)]
    }

    /// Steps a key press's spring to its landing, each frame waiting (at most 2 s) for its sizes to show.
    static func stepToLanding(_ screen: TerminalKeyResizeFrameTests.PaneScreen) async throws {
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = await TerminalKeyResizeFrameTests.stepFrame(screen).moving
            await Self.waitForShownSizes(screen)
            steps += 1
        }
        try #require(steps >= 2, "the press's spring ran \(steps) frames: no spring ran")
    }

    /// A full-screen program whose redraw at each new grid can be turned off (it then prints nothing after a resize, as a
    /// program busy at the moment of SIGWINCH), and that can set its background colour with OSC 11.
    nonisolated final class RingProgram: Sendable {
        private let state: Mutex<Bool>
        let background: (UInt8, UInt8, UInt8)?

        init(redraws: Bool, background: (UInt8, UInt8, UInt8)? = nil) {
            state = Mutex(redraws)
            self.background = background
        }

        var redraws: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }

        /// The first picture: the background (OSC 11) and the ring.
        func first(cols: Int, rows: Int) -> Data {
            let osc = background.map { String(format: "\u{1B}]11;rgb:%02x/%02x/%02x\u{1B}\\", $0.0, $0.1, $0.2) } ?? ""
            return Data(osc.utf8) + TerminalResizeProgramHoldTests.ring(cols: cols, rows: rows)
        }

        /// The answer to a new grid: the ring at it, or nothing.
        func redraw(cols: Int, rows: Int) -> Data {
            redraws ? TerminalResizeProgramHoldTests.ring(cols: cols, rows: rows) : Data()
        }
    }

    /// p1 | p2, each a full-screen program that draws its ring at its grid and redraws it at each new grid.
    static func ringScreen() async throws -> TerminalKeyResizeFrameTests.PaneScreen {
        try await ringScreen(RingProgram(redraws: true))
    }

    /// p1 | p2, each running `program`.
    static func ringScreen(_ program: RingProgram) async throws -> TerminalKeyResizeFrameTests.PaneScreen {
        let screen = try await TerminalKeyResizeFrameTests.PaneScreen(announcesGrids: true) { [program] cols, rows in
            program.redraw(cols: cols, rows: rows)
        }
        for (io, session) in zip(screen.ios, screen.sessions) {
            let grid = try #require(session.surfaceView.fittedGrid, "SETUP: a terminal fits no grid")
            io.send(.output(program.first(cols: grid.columns, rows: grid.rows)))
        }
        await TerminalKeyResizeFrameTests.settle(screen)
        return screen
    }

    /// Each frame waits (at most 2 s) for its sizes to show.
    static func waitForShownSizes(_ screen: TerminalKeyResizeFrameTests.PaneScreen) async {
        _ = await TerminalKeyResizeFrameTests.commits(screen, seconds: 2) {
            $0.sessions.allSatisfy(TerminalKeyResizeFrameTests.showsItsOwnFrame)
        }
    }

    /// In each pass, just before a frame is presented, what Ghostty says of it: drawn after the program's redraw at its
    /// grid (`READY_PROGRAM`) or of the size only (`READY`).
    @MainActor final class Presents {
        private let presenter: TerminalFramePresenter
        private(set) var program = 0
        private(set) var sizeOnly: [String] = []
        /// Each terminal's hold (``TerminalSurfaceView/programHoldTicks``) at its first present while this watches.
        private(set) var firstHoldTicks: [String: UInt64] = [:]

        init(_ screen: TerminalKeyResizeFrameTests.PaneScreen) {
            presenter = TerminalFramePresenter.forWindow(screen.window)
            presenter.presentingHook = { [weak self, unowned screen] view, state in
                guard let self else { return }
                let name = screen.sessions.firstIndex { $0.surfaceView === view }.map { "p\($0 + 1)" } ?? "?"
                if firstHoldTicks[name] == nil { firstHoldTicks[name] = view.programHoldTicks }
                if state == GHOSTTY_HOST_FRAME_READY_PROGRAM { program += 1 }
                if state == GHOSTTY_HOST_FRAME_READY {
                    let bounds = view.bounds.size, asked = view.frameOwnership.inFlight ?? .zero
                    sizeOnly.append("\(name): \(TerminalKeyResizeFrameTests.text(bounds)) -> \(TerminalKeyResizeFrameTests.text(asked))")
                }
            }
        }

        func stop() { presenter.presentingHook = nil }

        func check(_ what: String) throws {
            print("RESIZE P0 12 hold (\(what)): presents of the program's redraw \(program), of the size only \(sizeOnly.count)")
            try #require(program + sizeOnly.count >= 4, "\(what) presented \(program + sizeOnly.count) new sizes")
            #expect(sizeOnly.isEmpty,
                    "\(what): \(sizeOnly.count) frames showed a new size with the program's last picture, not its redraw at the new grid (3 ms after the send): \(sizeOnly.prefix(8))")
        }
    }

    /// A full-screen program's picture at `cols` x `rows`: the alternate screen, cleared, a ring on its edges.
    nonisolated static func ring(cols: Int, rows: Int) -> Data {
        guard cols >= 2, rows >= 2 else { return Data() }
        let edge = "+" + String(repeating: "-", count: cols - 2) + "+"
        let middle = "|" + String(repeating: " ", count: cols - 2) + "|"
        let lines = [edge] + Array(repeating: middle, count: rows - 2) + [edge]
        return Data(("\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\r\n")).utf8)
    }
}
