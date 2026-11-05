import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Darwin
import Foundation
import GhosttyNextKit
import Testing

/// cmux-ad m14, m18 and m26, window frame sync (Lead, 2026-11-05; design note PIXEL-PERFECT/WINDOW-FRAME-SYNC.md): in every
/// committed frame, every visible terminal shows pixels drawn at its layer's size (never stretched), and in a key spring its
/// layer has that frame's pane size: the frame of the next refresh's size is drawn ahead (m26, the Chromium model), so no
/// commit after the spring's first keeps an old size. A Reduce Motion jump has no next size: it may keep its last frame
/// and bounds for at most 2 refreshes (m18's allowance). The main thread never waits for a terminal's frame.
///
/// Today, with `motion.frameOwner.terminals` on, ``TerminalFramePresenter`` (ready-or-keep) keeps a terminal's OLD bounds
/// and frame until its new-size frame is ready (at most `keepLimit`, 6 refreshes), while the rest of the window already
/// moved. pixel-perfect's film rk-3t on-reduce shows that as a failure: Reduce Motion, one-jump shrink, p2 shows its old
/// wider frame for one refresh (frames 114 and 152).
///
/// The rig is `TerminalKeyResizeFrameTests.PaneScreen`: p1 | p2, each pane the app's `PaneContentView` with a real Ghostty
/// surface in its content area, in a borderless window on screen, the switch on, the layout driver stepped by the test.
/// The presses are the app's (`PaneResize.press`). A run-loop observer right after Core Animation's commit
/// (``CommitBoundary/order``, as `TerminalSurfaceCommitSizeTests.Fixture` samples) reads, in every committed main turn
/// from the press to rest, per terminal:
/// - (a) the bounds check: the surface layer's bounds equal its pane's surface area
///   (`TerminalHostView.surfaceSize(forHostSize:)` of the host's bounds), in pixels, at most 1 px off;
/// - (b) the frame check: the shown frame's size (the layer's IOSurface) equals the layer's bounds, at most 1 px off.
/// A second observer at the main run loop's wake stamps each turn, so each committed turn also has its awake time
/// (wall clock from the wake to the end of the commit) and its blocked time (that wall time less the main thread's CPU
/// time: time it was off the CPU, waiting).
///
/// A sampled turn is a main run-loop pass that ended with Core Animation's commit pass, not a display refresh: while the
/// test waits for rest it asks for commit after commit, so the run loop passes many times per refresh. So each failure
/// names its turn number and its time after the press, and each summary gives, per terminal, the failed turns and the
/// time of the last one (how long the old bounds stayed in the committed tree).
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalWindowFrameSyncTests {
    typealias Screen = TerminalKeyResizeFrameTests.PaneScreen

    /// Case 1. Reduce Motion, one Ctrl-Shift-L press on p2: the divider jumps right in one frame, p2 shrinks and p1
    /// grows. In every committed turn from the press to rest, each terminal shows a frame drawn at its layer's size (b);
    /// its layer has its pane's area (a) in every turn from 2 refreshes after the press on (a jump has no next size to
    /// draw ahead: the last frame and bounds stay until the new frame is drawn, m18's 2-refresh allowance).
    @Test func aReduceMotionOneJumpShrinkShowsEachTerminalAtItsPaneSizeInEveryCommittedTurn() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)

        let before = recorder.snapshot()
        let presentedBefore = TerminalFramePresenter.forWindow(screen.window).stats.presented
        let motion = await Self.jump(screen, recorder: recorder)
        let rest = recorder.snapshot()
        let turns = recorder.take()
        Self.diagDump("case1", screen, turns)

        try #require(motion.steps <= 2, "Reduce Motion: the press ran \(motion.steps) frames, so a spring ran")
        try #require(motion.moved, "Ctrl-Shift-L on p2 moved nothing")
        try #require(turns.count >= 3, "only \(turns.count) committed turns were sampled from the press to rest")
        try #require(before[1].area.width - rest[1].area.width >= 10,
                     "p2 did not shrink: its area went from \(before[1].area) to \(rest[1].area)")
        try #require(rest[0].area.width - before[0].area.width >= 10,
                     "p1 did not grow: its area went from \(before[0].area) to \(rest[0].area)")
        let presented = TerminalFramePresenter.forWindow(screen.window).stats.presented - presentedBefore
        try #require(presented > 0, "no new-size frame came through the presenter: the switch's path did not run")

        let allowance = 2 * Self.refreshMs(of: screen.window)
        let found = Self.check(turns, keepAllowedUntilMs: allowance)
        print("S4 m14 Reduce Motion one-jump shrink: \(turns.count) committed turns over \(Self.text(turns.last?.at ?? 0)) ms; " +
              "p1 \(before[0].area) -> \(rest[0].area), p2 \(before[1].area) -> \(rest[1].area); " +
              "bounds (a) failed in \(found.boundsTurns) turns (\(found.kept)), frame (b) in \(found.frameTurns); " +
              "presenter \(TerminalFramePresenter.forWindow(screen.window).stats)")
        #expect(found.bounds.isEmpty,
                "bounds check (a) failed in \(found.boundsTurns) of \(turns.count) committed turns (a terminal's layer is not its pane's area; turns per terminal: \(found.kept)): \(found.bounds.prefix(8))")
        #expect(found.frame.isEmpty,
                "frame check (b) failed in \(found.frameTurns) of \(turns.count) committed turns (the shown frame is not the layer's size): \(found.frame.prefix(8))")
    }

    /// Case 2. A key spring (normal motion), one Ctrl-Shift-L press on p2, stepped one frame per refresh as the frame
    /// tick runs it (the step, its layout pass, its commit, then commits until one refresh of wall-clock time passed, the
    /// time the renderer has to draw the size asked ahead), with output in both terminals every frame: the same two
    /// checks in every committed turn of the spring and up to rest. (b) catches an off-main present of a frame drawn
    /// ahead into the old bounds (a stretch). (a) holds from the spring's second frame on: its first frame has no size
    /// drawn ahead (m26: frames kept = 0 after the first commit).
    @Test func aKeySpringShowsEachTerminalAtItsPaneSizeInEveryCommittedTurn() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)

        let before = recorder.snapshot()
        let motion = await Self.spring(screen, recorder: recorder, pacedByRefresh: true)
        let rest = recorder.snapshot()
        let turns = recorder.take()
        Self.diagDump("case2", screen, turns)

        try #require(motion.moved, "Ctrl-Shift-L on p2 moved nothing")
        let ahead = TerminalFramePresenter.forWindow(screen.window).stats.drawnAhead
        try #require(ahead > 0, "no size was drawn ahead in the spring: the draw-ahead path did not run")
        // Held, not discarded (m26): the frame drawn at the size asked ahead in refresh n is the one its commit n+1
        // presents with those bounds, so no committed turn after the spring's first frame has a terminal still waiting
        // for its frame (a discarded ahead frame makes every spring frame wait one refresh).
        let waitedAfterFirst = turns.filter { $0.at > motion.firstFrameMs && $0.terminals.contains(where: \.waiting) }
        #expect(waitedAfterFirst.isEmpty,
                "\(waitedAfterFirst.count) committed turns after the spring's first frame had a terminal waiting for its frame (frames late after the first commit must be 0): \(waitedAfterFirst.prefix(6).map { "turn \($0.index) +\(Self.text($0.at)) ms" })")
        try #require(motion.steps >= 4, "the press's spring ran \(motion.steps) frames: no spring ran")
        try #require(before[1].area.width - rest[1].area.width >= 10,
                     "p2 did not shrink: its area went from \(before[1].area) to \(rest[1].area)")
        let widths = Set(turns.map { Int($0.terminals[1].area.width.rounded()) })
        try #require(widths.count > 3, "p2's area took only \(widths.count) widths in the spring: it did not move frame by frame")

        let found = Self.check(turns, keepAllowedUntilMs: motion.firstFrameMs)
        print("S4 m14 key spring: \(motion.steps) spring frames, \(turns.count) committed turns over \(Self.text(turns.last?.at ?? 0)) ms; " +
              "p2 took \(widths.count) widths; bounds (a) failed in \(found.boundsTurns) turns, frame (b) in \(found.frameTurns); " +
              "presenter \(TerminalFramePresenter.forWindow(screen.window).stats)")
        #expect(found.bounds.isEmpty,
                "bounds check (a) failed in \(found.boundsTurns) of \(turns.count) committed turns of the spring (a terminal's layer is not its pane's area; turns per terminal: \(found.kept)): \(found.bounds.prefix(8))")
        #expect(found.frame.isEmpty,
                "frame check (b) failed in \(found.frameTurns) of \(turns.count) committed turns of the spring (the shown frame is not the layer's size): \(found.frame.prefix(8))")
    }

    /// Case 4, the spring's end (m26): the last 3 spring frames and the commit after the landing each present a frame at
    /// their bounds, with no terminal waiting at the landing (the size drawn ahead for the landing is the one presented,
    /// and no repeated `set_size` at that size dropped it). Program output comes in every spring frame; after the landing
    /// the frame shown is one drawn after the last output reached the terminal (its text is in the viewport, and a newer
    /// frame of the layer's size shows within 2 s).
    @Test func aKeySpringsLastFramesAndItsLandingShowTheirOwnFramesWithTheNewText() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)

        let motion = await Self.spring(screen, recorder: recorder, pacedByRefresh: true)
        let turns = recorder.take()
        Self.diagDump("case4", screen, turns)
        try #require(motion.moved && motion.steps >= 4, "the press did not spring (moved \(motion.moved), \(motion.steps) frames)")
        let lastSteps = motion.stepMs.suffix(3)
        let from = try #require(lastSteps.first, "no spring frame was stepped")
        let landing = try #require(motion.stepMs.last)
        // The last 3 spring frames up to one refresh after the landing's step.
        let window = turns.filter { $0.at >= from && $0.at <= landing + Self.refreshMs(of: screen.window) }
        try #require(!window.isEmpty, "no committed turn was sampled at the spring's end")
        var off: [String] = []
        for turn in window {
            for (index, terminal) in turn.terminals.enumerated() {
                let label = "turn \(turn.index) (+\(Self.text(turn.at)) ms) p\(index + 1)"
                if terminal.waiting { off.append("\(label): waits for its frame") }
                if let shown = terminal.shown, !shown.isNear(terminal.layer) { off.append("\(label): shows \(shown) in a \(terminal.layer) layer") }
                if !terminal.layer.isNear(terminal.area) { off.append("\(label): layer \(terminal.layer), area \(terminal.area)") }
            }
        }
        #expect(off.isEmpty, "at the spring's end a terminal did not show its own frame at its bounds: \(off.prefix(8))")

        // New text after the landing: the frame that shows it is drawn and presented at the rest size.
        let marker = "landed-\(UUID().uuidString.prefix(8))"
        let shownBefore = screen.sessions.map { $0.surfaceView.presentedFrame }
        for io in screen.ios { io.send(.output(Data("\r\n\(marker)".utf8))) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        func showsMarker(_ index: Int) -> Bool {
            let view = screen.sessions[index].surfaceView
            guard view.viewportText()?.contains(marker) == true, let frame = view.presentedFrame, frame !== shownBefore[index],
                  let layer = view.layer else { return false }
            let scale = layer.contentsScale
            return Int((layer.bounds.width * scale).rounded()) == frame.width && Int((layer.bounds.height * scale).rounded()) == frame.height
        }
        while ContinuousClock.now < deadline, !screen.sessions.indices.allSatisfy(showsMarker) {
            await TerminalKeyResizeFrameTests.commit()
        }
        let missing = screen.sessions.indices.filter { !showsMarker($0) }.map { "p\($0 + 1)" }
        #expect(missing.isEmpty, "after the landing no frame drawn after the new text showed at the rest size within 2 s: \(missing)")
    }

    /// Case 5, the PTY gets only sizes its pane SHOWED (resize owner, film finding, STATUS 14461; cmux-ad m18 and m26).
    /// A held key (3 Ctrl-Shift-L presses 4 spring frames apart, one spring retargeted), stepped one frame per refresh with
    /// output in both terminals and an owner that announces each grid it gets (the daemon), so announcements arrive while
    /// a size drawn ahead is with Ghostty. The size drawn ahead goes to Ghostty's render only:
    /// - (a) in every committed turn, the grid the view gives its PTY owner is the grid its committed layer bounds fit;
    /// - (b) every grid the PTY gets is a grid that a committed turn showed;
    /// - (c) two grids are at least 25 ms apart (Ghostty.app's `min_ms`) before the landing (the landing flushes);
    /// - (d) after the shown grid changes, the PTY gets a grid within 25 ms (plus 2 refreshes and a slack for the runner);
    /// - (e) the last grid is the grid the pane rests at.
    @Test func aHeldKeyResizeGivesThePTYOnlyGridsThePaneShowedAtMostEvery25ms() async throws {
        let screen = try await Screen(announcesGrids: true)
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)
        let owners = screen.sessions.compactMap { $0.io as? AnnouncingTerminalIO }
        try #require(owners.count == screen.sessions.count, "SETUP: a terminal's owner does not record its reports")
        for owner in owners { owner.reports.withLock { $0.removeAll() } }

        let motion = await Self.spring(screen, recorder: recorder, pacedByRefresh: true, presses: 3)
        let turns = recorder.take()
        Self.diagDump("case5", screen, turns)
        let origin = try #require(recorder.origin, "the recorder never started")
        try #require(motion.moved && motion.steps >= 10, "the held key did not spring (moved \(motion.moved), \(motion.steps) frames)")
        let landingMs = try #require(motion.stepMs.last)
        let refresh = Self.refreshMs(of: screen.window)
        let interval = TerminalGridReportCoalescer.defaultInterval.components
        let window = Double(interval.seconds) * 1000 + Double(interval.attoseconds) / 1e15
        let liveness = window + 2 * refresh + Self.runnerSlackMs

        var unshownView: [String] = [], unshownPTY: [String] = [], close: [String] = [], late: [String] = [], ends: [String] = []
        for (index, owner) in owners.enumerated() {
            let name = "p\(index + 1)"
            let reports = owner.reports.withLock { $0 }.map { (grid: $0.grid, ms: TurnRecorder.ms(origin.duration(to: $0.at))) }
            // (a)
            for turn in turns {
                let terminal = turn.terminals[index]
                if let shown = terminal.shownGrid, let view = terminal.viewGrid, shown != view {
                    unshownView.append("\(name) turn \(turn.index) (+\(Self.text(turn.at)) ms): view grid \(Self.text(view)), shown \(Self.text(shown))")
                }
            }
            // (b)
            let shownGrids = turns.compactMap { $0.terminals[index].shownGrid }
            for report in reports where !shownGrids.contains(report.grid) {
                unshownPTY.append("\(name) +\(Self.text(report.ms)) ms: \(Self.text(report.grid)), never shown")
            }
            // (c)
            for (previous, next) in zip(reports, reports.dropFirst()) where next.ms < landingMs && next.ms - previous.ms < window - 1 {
                close.append("\(name): \(Self.text(previous.grid)) at +\(Self.text(previous.ms)) ms, \(Self.text(next.grid)) at +\(Self.text(next.ms)) ms")
            }
            // (d): the turns and the reports in time order; a change starts when a turn shows a grid the PTY has not got.
            var sent = turns.first?.terminals[index].shownGrid, changedAt: Double?, next = 0
            for turn in turns {
                while next < reports.count, reports[next].ms <= turn.at {
                    if let changed = changedAt, reports[next].ms - changed > liveness {
                        late.append("\(name): the shown grid changed at +\(Self.text(changed)) ms, the PTY got a grid at +\(Self.text(reports[next].ms)) ms")
                    }
                    (sent, changedAt) = (reports[next].grid, nil)
                    next += 1
                }
                guard let shown = turn.terminals[index].shownGrid else { continue }
                if shown == sent {
                    changedAt = nil
                } else if changedAt == nil {
                    changedAt = turn.at
                }
            }
            if let changed = changedAt {
                late.append("\(name): the shown grid changed at +\(Self.text(changed)) ms and the PTY never got it")
            }
            // (e)
            let rest = screen.sessions[index].surfaceView.fittedGrid
            if reports.last?.grid != rest {
                ends.append("\(name): the PTY's last grid is \(Self.text(reports.last?.grid)), the pane rests at \(Self.text(rest))")
            }
            print("S4 m26 PTY grids \(name): \(reports.map { "\(Self.text($0.grid))@\(Self.text($0.ms))" }.joined(separator: " ")); " +
                  "landing +\(Self.text(landingMs)) ms")
        }
        #expect(unshownView.isEmpty,
                "\(unshownView.count) committed turns gave the PTY owner a grid the pane did not show (a size drawn ahead reached geometry): \(unshownView.prefix(6))")
        #expect(unshownPTY.isEmpty, "the PTY got grids no committed turn showed: \(unshownPTY.prefix(6))")
        #expect(close.isEmpty, "the PTY got two grids less than 25 ms apart before the landing: \(close.prefix(6))")
        #expect(late.isEmpty, "the PTY got a changed grid more than \(Self.text(liveness)) ms after the pane showed it: \(late.prefix(6))")
        #expect(ends.isEmpty, "\(ends)")
    }

    /// DIAG (never merge): the presenter's trace, timings and counts, the coalescers' traces, and per turn the drawn grid.
    @MainActor static func diagDump(_ name: String, _ screen: Screen, _ turns: [TurnRecorder.Turn]) {
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        print("DIAG \(name) nextFrameInterval \(MotionClock.forWindow(screen.window).nextFrameInterval) counts \(presenter.diagCounts)")
        for (key, value) in presenter.diagMax.sorted(by: { $0.value.ms > $1.value.ms }) { print("DIAG \(name) max \(key) \(String(format: "%.3f", value.ms)) ms") }
        for line in presenter.diagLines.prefix(1500) { print("DIAG \(name) T \(line)") }
        for (index, session) in screen.sessions.enumerated() {
            for event in session.surfaceView.gridReportCoalescer.diagTrace {
                print("DIAG \(name) C p\(index + 1) \(event.0) \(event.1.map { "\($0.columns)x\($0.rows)" } ?? "-") @\(TurnRecorder.ms(TerminalFramePresenter.diagZero.duration(to: event.2)))")
            }
        }
        for turn in turns.prefix(400) {
            let parts = turn.terminals.enumerated().map { index, t in
                "p\(index + 1) layer \(t.layer) area \(t.area) shown \(t.shown.map { "\($0)" } ?? "-") wait \(t.waiting) shownGrid \(Self.text(t.shownGrid)) viewGrid \(Self.text(t.viewGrid)) drawn \(Self.text(t.drawnGrid))"
            }
            print("DIAG \(name) turn \(turn.index) +\(Self.text(turn.at)) awake \(turn.awakeMs.map { Self.text($0) } ?? "-") blocked \(turn.blockedMs.map { Self.text($0) } ?? "-") \(parts.joined(separator: " | "))")
        }
        presenter.diagLines.removeAll()
        presenter.diagMax.removeAll()
        presenter.diagCounts.removeAll()
        for session in screen.sessions { session.surfaceView.gridReportCoalescer.diagTrace.removeAll() }
    }

    /// Wall-clock slack for a loaded runner in the timing checks of case 5.
    static let runnerSlackMs = 8.0

    static func text(_ grid: TerminalGridSize?) -> String { grid.map { "\($0.columns)x\($0.rows)" } ?? "none" }

    /// Case 3. The main thread is never blocked by a sync: in a Reduce Motion jump and in a key spring, no committed
    /// turn from the press to rest is awake longer than ``awakeLimitMs`` or off the CPU longer than ``blockedLimitMs``.
    ///
    /// The bounds. Awake: 2 refreshes at 60 Hz (33.3 ms), on a turn that does only the press, one stepped frame, the
    /// presenter's pass and the commit (a few ms on a fleet Mac; `TerminalSurfaceCommitSizeTests` holds the key turn's
    /// median under 8.33 ms). Blocked: 1 refresh at 60 Hz (16.7 ms), the sync's own deadline: a main thread that waits
    /// for a terminal's frame (a sync on main, or a display pass that waits for the renderer) is off the CPU for that
    /// wait, while work and a short `[CATransaction lock]` are not. 60 Hz, not the display's rate, so a 120 Hz host is
    /// not held to half the time: the bounds catch a wait, not a slow host.
    @Test func theMainThreadIsNeverBlockedForATerminalsFrameInAJumpOrASpring() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)

        let jump = await Self.jump(screen, recorder: recorder)
        let jumpTurns = recorder.take()
        Self.diagDump("case3jump", screen, jumpTurns)
        let spring = await Self.spring(screen, recorder: recorder, direction: .left)
        let springTurns = recorder.take()
        Self.diagDump("case3spring", screen, springTurns)

        try #require(jump.moved && jump.steps <= 2, "the Reduce Motion press did not jump (moved \(jump.moved), \(jump.steps) frames)")
        try #require(spring.moved && spring.steps >= 4, "the spring press did not spring (moved \(spring.moved), \(spring.steps) frames)")
        var violations: [String] = []
        var timed = 0, waited = 0
        var awake: [Double] = [], blocked: [Double] = []
        for (name, turns) in [("jump", jumpTurns), ("spring", springTurns)] {
            for turn in turns {
                if turn.terminals.contains(where: \.waiting) { waited += 1 }
                guard let awakeMs = turn.awakeMs, let blockedMs = turn.blockedMs else { continue }
                timed += 1
                awake.append(awakeMs)
                blocked.append(blockedMs)
                if awakeMs > Self.awakeLimitMs || blockedMs > Self.blockedLimitMs {
                    violations.append("\(name) turn \(turn.index) (+\(Self.text(turn.at)) ms): awake \(Self.text(awakeMs)) ms, blocked \(Self.text(blockedMs)) ms")
                }
            }
        }
        try #require(timed >= 10, "only \(timed) committed turns were timed: the case saw too few turns")
        try #require(waited > 0, "no sampled turn had a terminal waiting for its frame: the case never covered a wait")
        print("S4 m14 main thread: \(timed) timed turns (\(waited) with a terminal waiting for its frame); awake ms \(Self.summary(awake)); " +
              "blocked ms \(Self.summary(blocked)); limits awake \(Self.text(Self.awakeLimitMs)), blocked \(Self.text(Self.blockedLimitMs))")
        #expect(violations.isEmpty,
                "\(violations.count) committed turns were awake longer than \(Self.text(Self.awakeLimitMs)) ms or blocked longer than \(Self.text(Self.blockedLimitMs)) ms: \(violations.prefix(8))")
    }

    /// 1 refresh of `window`'s display in ms: its shortest frame interval; 1/60 s with no screen.
    static func refreshMs(of window: NSWindow) -> Double {
        let interval = window.screen?.minimumRefreshInterval ?? 0
        return (interval > 0 ? interval : 1.0 / 60) * 1000
    }

    /// The longest a committed turn of the motion may be awake: 2 refreshes at 60 Hz.
    static let awakeLimitMs = 2 * 1000.0 / 60
    /// The longest a committed turn of the motion may be off the CPU: 1 refresh at 60 Hz.
    static let blockedLimitMs = 1000.0 / 60

    // MARK: Motions

    /// Warm-up press (Ctrl-Shift-H on p2, a spring) and rest: one-time setup is not the press under test, and the split
    /// is at 0.45 so the next Ctrl-Shift-L shrinks p2.
    static func warmUp(_ screen: Screen) async throws {
        screen.root.context.reduceMotionOverride = false
        try #require(PaneResize.press("p2", .left, model: screen.model, view: screen.root), "the warm-up press moved nothing")
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
            steps += 1
        }
        await rest(screen)
    }

    /// Reduce Motion, one Ctrl-Shift-L press on p2, recorded from the press to rest. No layout pass of the test's own:
    /// the press presents in the key's turn and AppKit's display cycle lays the hosts out, as in the app.
    static func jump(_ screen: Screen, recorder: TurnRecorder) async -> (moved: Bool, steps: Int) {
        screen.root.context.reduceMotionOverride = true
        defer { screen.root.context.reduceMotionOverride = false }
        let frame = screen.root.context.hosts["p2"]?.frame
        recorder.start()
        let pressed = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var moving = true, steps = 0
        while moving, steps < 4 {
            moving = screen.root.advanceFrame(1.0 / 120)
            await TerminalKeyResizeFrameTests.commit()
            steps += 1
        }
        await rest(screen)
        recorder.pause()
        return (pressed && screen.root.context.hosts["p2"]?.frame != frame, steps)
    }

    /// Normal motion, one press on p2 (`direction`, default Ctrl-Shift-L: p2 shrinks), stepped one frame per commit
    /// (the step, its layout pass, its commit) to the landing, recorded from the press to rest.
    /// `pacedByRefresh`: after each frame's commit, commits until one refresh of wall-clock time passed since the step
    /// (the renderer draws the size asked ahead meanwhile), with a line of output in each terminal. Returns whether p2
    /// moved, the frames stepped, and when (ms after the press) the spring's second frame was stepped.
    /// `presses`: a held key, that many presses `framesBetweenPresses` spring frames apart (a key repeat), retargeting the
    /// one spring.
    static func spring(_ screen: Screen, recorder: TurnRecorder, direction: LayoutDirection = .right,
                       pacedByRefresh: Bool = false, presses: Int = 1,
                       framesBetweenPresses: Int = 4) async -> (moved: Bool, steps: Int, firstFrameMs: Double, stepMs: [Double]) {
        screen.root.context.reduceMotionOverride = false
        let frame = screen.root.context.hosts["p2"]?.frame
        let refresh = Duration.milliseconds(refreshMs(of: screen.window))
        recorder.start()
        let pressed = ContinuousClock.now
        let moved = PaneResize.press("p2", direction, model: screen.model, view: screen.root)
        var moving = true, steps = 0, firstFrameMs = 0.0, stepMs: [Double] = []
        while moving, steps < 240 {
            let stepped = ContinuousClock.now
            stepMs.append(TurnRecorder.ms(pressed.duration(to: stepped)))
            if steps == 1 { firstFrameMs = TurnRecorder.ms(pressed.duration(to: stepped)) }
            if steps > 0, steps % framesBetweenPresses == 0, steps / framesBetweenPresses < presses {
                _ = PaneResize.press("p2", direction, model: screen.model, view: screen.root)
            }
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
            if pacedByRefresh {
                for io in screen.ios { io.send(.output(Data("\r\nframe \(steps)".utf8))) }
                while stepped.duration(to: .now) < refresh { await TerminalKeyResizeFrameTests.commit() }
            }
            steps += 1
        }
        await rest(screen)
        recorder.pause()
        return (moved && screen.root.context.hosts["p2"]?.frame != frame, steps, firstFrameMs, stepMs)
    }

    /// Commits until no terminal waits for its frame and the hosts and surface layers have not changed for 300 ms of
    /// wall-clock time (at most 3 s).
    static func rest(_ screen: Screen) async {
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var last: [CGSize] = []
        var changed = ContinuousClock.now
        while ContinuousClock.now < deadline,
              changed.duration(to: .now) < .milliseconds(300) || screen.sessions.contains(where: { presenter.isWaiting($0.surfaceView) }) {
            await TerminalKeyResizeFrameTests.commit()
            let now = screen.sessions.flatMap { [$0.view.bounds.size, $0.surfaceView.layer?.bounds.size ?? .zero] }
            if now != last { (last, changed) = (now, .now) }
        }
    }

    // MARK: Checks

    /// The failures of checks (a) and (b) in `turns`, one line each, and how many turns had each.
    /// `keepAllowedUntilMs`: a turn up to that time after the press may keep a terminal's old bounds (check (a)), with the
    /// frame drawn at them (check (b) holds in every turn).
    static func check(_ turns: [TurnRecorder.Turn], keepAllowedUntilMs: Double = 0)
        -> (bounds: [String], frame: [String], boundsTurns: Int, frameTurns: Int, kept: String) {
        var bounds: [String] = [], frame: [String] = []
        var boundsTurns = 0, frameTurns = 0
        // Per terminal: the committed turns in which its layer was not its pane's area (kept old bounds).
        var keptTurns = Array(repeating: 0, count: turns.first?.terminals.count ?? 0)
        var keptUntil = Array(repeating: 0.0, count: keptTurns.count)
        for turn in turns {
            var boundsFailed = false, frameFailed = false
            for (index, terminal) in turn.terminals.enumerated() {
                let name = "turn \(turn.index) (+\(text(turn.at)) ms) p\(index + 1)\(terminal.waiting ? " (its new size waits for its frame)" : "")"
                if !terminal.layer.isNear(terminal.area), turn.at > keepAllowedUntilMs {
                    boundsFailed = true
                    if keptTurns.indices.contains(index) {
                        keptTurns[index] += 1
                        keptUntil[index] = max(keptUntil[index], turn.at)
                    }
                    bounds.append("\(name): bounds check (a): layer \(terminal.layer) px, pane area \(terminal.area) px, " +
                                  "shown frame \(terminal.shown.map { "\($0)" } ?? "none") px")
                }
                if let shown = terminal.shown {
                    if !shown.isNear(terminal.layer) {
                        frameFailed = true
                        frame.append("\(name): frame check (b): shown frame \(shown) px, layer \(terminal.layer) px")
                    }
                } else {
                    frameFailed = true
                    frame.append("\(name): frame check (b): no frame shown, layer \(terminal.layer) px")
                }
            }
            if boundsFailed { boundsTurns += 1 }
            if frameFailed { frameTurns += 1 }
        }
        let kept = keptTurns.indices.map { "p\($0 + 1) \(keptTurns[$0]) turns, last at +\(text(keptUntil[$0])) ms" }.joined(separator: "; ")
        return (bounds, frame, boundsTurns, frameTurns, kept)
    }

    static func text(_ ms: Double) -> String { String(format: "%.2f", ms) }

    /// p50, p95 and max of `values`, for messages.
    static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard let last = sorted.last else { return "none" }
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return "p50 \(text(p(0.5))) p95 \(text(p(0.95))) max \(text(last))"
    }

    // MARK: Recorder

    /// Samples every committed main run-loop turn while it records: per terminal, its layer's bounds, its pane's surface
    /// area and its shown frame, in pixels, and whether the presenter keeps it waiting for its frame; per turn, its
    /// awake and blocked time.
    final class TurnRecorder {
        /// A size in device pixels.
        struct Pixels: CustomStringConvertible {
            var width: Double
            var height: Double
            var description: String { "\(Int(width.rounded()))x\(Int(height.rounded()))" }

            func isNear(_ other: Pixels) -> Bool { abs(width - other.width) <= 1 && abs(height - other.height) <= 1 }
        }

        /// One terminal in one committed turn.
        struct Terminal {
            var layer: Pixels
            var area: Pixels
            var shown: Pixels?
            var waiting: Bool
            /// The grid its committed layer bounds fit (`ghostty_surface_fit_grid` of the layer's pixel size): the grid the
            /// pane shows in this turn.
            var shownGrid: TerminalGridSize?
            /// The grid the view gives its PTY owner (``TerminalSurfaceView/fittedGrid``).
            var viewGrid: TerminalGridSize?            /// DIAG: the grid of the renderer's last frame update.
            var drawnGrid: TerminalGridSize?
        }

        /// One committed turn: its number from the press (1 is the press's turn), its time after the press (ms), its
        /// terminals (p1, p2), and its awake and blocked time (ms; nil when the turn's wake was not seen).
        struct Turn {
            var index: Int
            var at: Double
            var terminals: [Terminal]
            var awakeMs: Double?
            var blockedMs: Double?
        }

        private let screen: Screen
        private var wake: MainRunLoopObserver?
        private var commit: MainRunLoopObserver?
        /// When the main run loop last woke: wall clock and the main thread's CPU time.
        private var woke: (at: ContinuousClock.Instant, cpu: UInt64)?
        private var started: ContinuousClock.Instant?
        private var turns: [Turn] = []

        @MainActor init(_ screen: Screen) {
            self.screen = screen
            // The earliest observer of the wake: each turn's awake time starts here.
            wake = MainRunLoopObserver(activities: .afterWaiting, order: CFIndex.min) { [weak self] _ in
                self?.woke = (.now, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
            }
            // Right after Core Animation's commit: what this turn committed.
            commit = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                         drawsNothingAfterCommit: true) { [weak self] _ in self?.sample() }
        }

        func stop() {
            wake = nil
            commit = nil
        }

        /// Records from now on; the press comes in this turn.
        func start() {
            turns.removeAll()
            started = .now
            origin = started
        }

        /// When the last ``start()`` was (kept after ``pause()``): the zero of every turn's ``Turn/at``.
        private(set) var origin: ContinuousClock.Instant?

        func pause() { started = nil }

        /// The turns recorded since ``start()``.
        var turnCount: Int { turns.count }

        /// The turns recorded since ``start()``, and an empty record.
        @MainActor func take() -> [Turn] {
            defer { turns.removeAll() }
            return turns
        }

        /// The terminals now (p1, p2).
        @MainActor func snapshot() -> [(area: Pixels, layer: Pixels)] {
            terminals().map { ($0.area, $0.layer) }
        }

        @MainActor private func terminals() -> [Terminal] {
            let presenter = TerminalFramePresenter.forWindow(screen.window)
            return screen.sessions.map { session in
                let surface = session.surfaceView
                let host = session.view
                let scale = Double(surface.layer?.contentsScale ?? 2)
                let bounds = surface.layer?.bounds.size ?? .zero
                let area = host.surfaceSize(forHostSize: host.bounds.size)
                return Terminal(layer: Pixels(width: bounds.width * scale, height: bounds.height * scale),
                                area: Pixels(width: area.width * scale, height: area.height * scale),
                                shown: surface.presentedFrame.map { Pixels(width: Double($0.width), height: Double($0.height)) },
                                waiting: presenter.isWaiting(surface),
                                shownGrid: Self.fitGrid(surface, pixels: CGSize(width: bounds.width * scale, height: bounds.height * scale)),
                                viewGrid: surface.fittedGrid, drawnGrid: Self.drawnGrid(surface))
            }
        }

        @MainActor private func sample() {
            guard let started else { return }
            let end = ContinuousClock.now
            var awakeMs: Double?, blockedMs: Double?
            if let woke, woke.at >= started || turns.isEmpty {
                let wall = Self.ms(woke.at.duration(to: end))
                let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- woke.cpu) / 1e6
                awakeMs = wall
                blockedMs = max(0, wall - cpu)
            }
            woke = nil
            turns.append(Turn(index: turns.count + 1, at: Self.ms(started.duration(to: end)), terminals: terminals(),
                              awakeMs: awakeMs, blockedMs: blockedMs))
        }

        @MainActor static func drawnGrid(_ view: TerminalSurfaceView) -> TerminalGridSize? {
            var columns: UInt16 = 0, rows: UInt16 = 0
            guard let surface = view.surface, ghostty_surface_drawn_grid(surface, &columns, &rows) else { return nil }
            return TerminalGridSize(columns: Int(columns), rows: Int(rows))
        }

        /// The grid a view of `pixels` fits, with `view`'s surface's cell size and padding.
        @MainActor static func fitGrid(_ view: TerminalSurfaceView, pixels: CGSize) -> TerminalGridSize? {
            var columns: UInt16 = 0, rows: UInt16 = 0
            guard let surface = view.surface, pixels.width >= 1, pixels.height >= 1,
                  ghostty_surface_fit_grid(surface, UInt32(pixels.width.rounded()), UInt32(pixels.height.rounded()), &columns, &rows)
            else { return nil }
            return TerminalGridSize(columns: Int(columns), rows: Int(rows))
        }

        static func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
    }
}
