import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// cmux-ad m14, window frame sync (Lead, 2026-11-05; design note PIXEL-PERFECT/WINDOW-FRAME-SYNC.md): in every committed
/// frame, every visible terminal shows pixels drawn at that frame's pane size. An old frame kept at a new pane size is a
/// failure, also for one refresh. The main thread never waits for a terminal's frame.
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
    /// grows. In every committed turn from the press to rest, each terminal's layer has its pane's area (a) and shows a
    /// frame drawn at that size (b). Today (a) fails in the turns where the presenter keeps a terminal's old bounds.
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

        try #require(motion.steps <= 2, "Reduce Motion: the press ran \(motion.steps) frames, so a spring ran")
        try #require(motion.moved, "Ctrl-Shift-L on p2 moved nothing")
        try #require(turns.count >= 3, "only \(turns.count) committed turns were sampled from the press to rest")
        try #require(before[1].area.width - rest[1].area.width >= 10,
                     "p2 did not shrink: its area went from \(before[1].area) to \(rest[1].area)")
        try #require(rest[0].area.width - before[0].area.width >= 10,
                     "p1 did not grow: its area went from \(before[0].area) to \(rest[0].area)")
        let presented = TerminalFramePresenter.forWindow(screen.window).stats.presented - presentedBefore
        try #require(presented > 0, "no new-size frame came through the presenter: the switch's path did not run")

        let found = Self.check(turns)
        print("S4 m14 Reduce Motion one-jump shrink: \(turns.count) committed turns over \(Self.text(turns.last?.at ?? 0)) ms; " +
              "p1 \(before[0].area) -> \(rest[0].area), p2 \(before[1].area) -> \(rest[1].area); " +
              "bounds (a) failed in \(found.boundsTurns) turns (\(found.kept)), frame (b) in \(found.frameTurns); " +
              "presenter \(TerminalFramePresenter.forWindow(screen.window).stats)")
        #expect(found.bounds.isEmpty,
                "bounds check (a) failed in \(found.boundsTurns) of \(turns.count) committed turns (a terminal's layer is not its pane's area; turns per terminal: \(found.kept)): \(found.bounds.prefix(8))")
        #expect(found.frame.isEmpty,
                "frame check (b) failed in \(found.frameTurns) of \(turns.count) committed turns (the shown frame is not the layer's size): \(found.frame.prefix(8))")
    }

    /// Case 2. A key spring (normal motion), one Ctrl-Shift-L press on p2, stepped one frame per commit as the frame
    /// tick runs it: the same two checks in every committed turn of the spring and up to rest. It guards the draw-ahead
    /// work (the frame of the size at refresh N+1 asked at N), so it stays even when it does not fail.
    @Test func aKeySpringShowsEachTerminalAtItsPaneSizeInEveryCommittedTurn() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)

        let before = recorder.snapshot()
        let motion = await Self.spring(screen, recorder: recorder)
        let rest = recorder.snapshot()
        let turns = recorder.take()

        try #require(motion.moved, "Ctrl-Shift-L on p2 moved nothing")
        try #require(motion.steps >= 4, "the press's spring ran \(motion.steps) frames: no spring ran")
        try #require(before[1].area.width - rest[1].area.width >= 10,
                     "p2 did not shrink: its area went from \(before[1].area) to \(rest[1].area)")
        let widths = Set(turns.map { Int($0.terminals[1].area.width.rounded()) })
        try #require(widths.count > 3, "p2's area took only \(widths.count) widths in the spring: it did not move frame by frame")

        let found = Self.check(turns)
        print("S4 m14 key spring: \(motion.steps) spring frames, \(turns.count) committed turns over \(Self.text(turns.last?.at ?? 0)) ms; " +
              "p2 took \(widths.count) widths; bounds (a) failed in \(found.boundsTurns) turns, frame (b) in \(found.frameTurns); " +
              "presenter \(TerminalFramePresenter.forWindow(screen.window).stats)")
        #expect(found.bounds.isEmpty,
                "bounds check (a) failed in \(found.boundsTurns) of \(turns.count) committed turns of the spring (a terminal's layer is not its pane's area; turns per terminal: \(found.kept)): \(found.bounds.prefix(8))")
        #expect(found.frame.isEmpty,
                "frame check (b) failed in \(found.frameTurns) of \(turns.count) committed turns of the spring (the shown frame is not the layer's size): \(found.frame.prefix(8))")
    }

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
        let spring = await Self.spring(screen, recorder: recorder, direction: .left)
        let springTurns = recorder.take()

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

    /// Case 4, the Lead's hard rule for the sync's deadline: a terminal that joins the window's sync and never presents
    /// its new-size frame (a stalled renderer) holds the window's fence for at most 1 refresh. Then the fence is
    /// released, `debug.frames` counts `sync_deadline_missed` once for that terminal (and not for the one that
    /// presented), the terminal that presented shows its pane's size from the sync's commit on, and no main turn waits
    /// for the stalled one. Reduce Motion, one Ctrl-Shift-L press on p2 (both terminals change size in one commit, so
    /// both join); p2 never presents.
    ///
    /// The deadline is 1 refresh of the window's display (`NSScreen.minimumRefreshInterval`: 8.33 ms at 120 Hz,
    /// 16.7 ms at 60 Hz; 16.7 ms with no screen), measured by the sync itself from its commit to the fence's release
    /// (``WindowFrameSyncDeadlineSeam/lastSync(in:)``), not by the test's turns.
    ///
    /// Disabled until the window frame sync exists: the base has no fence, so this case cannot run there. It is written
    /// against ``WindowFrameSyncDeadlineSeam``, which the implementation provides (``deadlineSeam``).
    @Test(.disabled("needs the window frame sync"))
    func aJoinedSurfaceThatNeverPresentsReleasesTheFenceWithinOneRefreshAndCountsADeadlineMiss() async throws {
        let seam = try #require(Self.deadlineSeam, "the window frame sync gives this suite no WindowFrameSyncDeadlineSeam (deadlineSeam is nil)")
        let screen = try await Screen()
        defer { screen.close() }
        let recorder = TurnRecorder(screen)
        defer { recorder.stop() }
        try await Self.warmUp(screen)
        let window = screen.window
        let presenting = screen.sessions[0].surfaceView, stalled = screen.sessions[1].surfaceView
        let missedBefore = (p1: seam.syncDeadlineMissed(of: presenting, in: window), p2: seam.syncDeadlineMissed(of: stalled, in: window))
        let refresh = Self.refreshMs(of: window)
        seam.stallPresents(of: stalled, in: window)
        defer { seam.resumePresents(of: stalled, in: window) }

        screen.root.context.reduceMotionOverride = true
        let before = recorder.snapshot()
        recorder.start()
        let moved = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        // Commits until the fence is released (at most 1 s of wall-clock time; the fence never holds a main turn).
        var heldTurns = 0, releasedAtTurn: Int?
        let giveUp = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < giveUp {
            _ = screen.root.advanceFrame(1.0 / 120)
            await TerminalKeyResizeFrameTests.commit()
            if seam.isFenceHeld(in: window) {
                heldTurns += 1
            } else if heldTurns > 0 {
                releasedAtTurn = recorder.turnCount
                break
            }
        }
        await Self.rest(screen)
        recorder.pause()
        screen.root.context.reduceMotionOverride = false
        let turns = recorder.take()
        let rest = recorder.snapshot()

        try #require(moved, "Ctrl-Shift-L on p2 moved nothing")
        try #require(before[1].area.width - rest[1].area.width >= 10, "p2 did not shrink: its area went from \(before[1].area) to \(rest[1].area)")
        try #require(heldTurns > 0, "the window's fence was never held: p2 did not join the window's sync, so the case under test did not happen")
        let sync = try #require(seam.lastSync(in: window), "the window frame sync recorded no sync for the press")
        try #require(sync.joined >= 2, "only \(sync.joined) surfaces joined the press's sync: both terminals changed size in its commit")
        let missedAfter = (p1: seam.syncDeadlineMissed(of: presenting, in: window), p2: seam.syncDeadlineMissed(of: stalled, in: window))
        let heldMs = TurnRecorder.ms(sync.heldFor)
        print("S4 m14 sync deadline: fence held \(Self.text(heldMs)) ms (deadline \(Self.text(refresh)) ms), seen held in \(heldTurns) turns, " +
              "released by turn \(releasedAtTurn.map(String.init) ?? "never"); sync_deadline_missed p1 \(missedBefore.p1) -> \(missedAfter.p1), " +
              "p2 \(missedBefore.p2) -> \(missedAfter.p2)")

        #expect(releasedAtTurn != nil, "the window's fence was still held 1 s after the press, for a surface that never presented")
        #expect(heldMs <= refresh,
                "the window's fence was held \(Self.text(heldMs)) ms for a surface that never presented; the deadline is 1 refresh (\(Self.text(refresh)) ms)")
        #expect(sync.deadlineMissed, "the sync reached its deadline with p2 unpresented but did not record the miss")
        #expect(missedAfter.p2 == missedBefore.p2 + 1,
                "debug.frames sync_deadline_missed for p2 (never presented) went from \(missedBefore.p2) to \(missedAfter.p2); expected exactly 1 more")
        #expect(missedAfter.p1 == missedBefore.p1,
                "debug.frames sync_deadline_missed for p1 (presented) went from \(missedBefore.p1) to \(missedAfter.p1); expected no change")
        // The surface that presented shows its pane's size in every committed turn (the sync's commit carries it).
        let found = Self.check(turns.map { turn in
            var p1Only = turn
            p1Only.terminals = Array(turn.terminals.prefix(1))
            return p1Only
        })
        #expect(found.bounds.isEmpty && found.frame.isEmpty,
                "p1 (presented) was not at its pane's size in every committed turn while p2 missed the deadline: \((found.bounds + found.frame).prefix(8))")
        let blocked = turns.compactMap { turn in
            turn.blockedMs.flatMap { $0 > Self.blockedLimitMs ? "turn \(turn.index): blocked \(Self.text($0)) ms" : nil }
        }
        #expect(blocked.isEmpty, "a main turn waited for the stalled surface (blocked longer than \(Self.text(Self.blockedLimitMs)) ms): \(blocked.prefix(8))")
    }

    /// 1 refresh of `window`'s display in ms: its shortest frame interval; 1/60 s with no screen.
    static func refreshMs(of window: NSWindow) -> Double {
        let interval = window.screen?.minimumRefreshInterval ?? 0
        return (interval > 0 ? interval : 1.0 / 60) * 1000
    }

    // MARK: Deadline seam

    /// What the window frame sync (m14) gives this suite for the deadline case. The base has no sync, so the suite
    /// declares the seam and ``deadlineSeam`` is nil: the case is disabled. The implementation provides a conforming
    /// adapter (test support over its own debug hooks), sets ``deadlineSeam`` to it and removes the `.disabled` trait,
    /// with the assertion texts unchanged.
    protocol WindowFrameSyncDeadlineSeam {
        /// The window's last sync: how many surfaces joined it, how long its fence was held (from the sync's commit to the
        /// fence's release, measured by the sync), and whether it reached its deadline. Nil before the first sync.
        func lastSync(in window: NSWindow) -> (joined: Int, heldFor: Duration, deadlineMissed: Bool)?
        /// Whether `window`'s fence holds a commit now.
        func isFenceHeld(in window: NSWindow) -> Bool
        /// `view`'s `sync_deadline_missed` count in `debug.frames`.
        func syncDeadlineMissed(of view: TerminalSurfaceView, in window: NSWindow) -> Int
        /// From now on `view` draws but never presents a frame at a new size (a stalled renderer); it still joins syncs.
        func stallPresents(of view: TerminalSurfaceView, in window: NSWindow)
        /// `view` presents again.
        func resumePresents(of view: TerminalSurfaceView, in window: NSWindow)
    }

    /// The window frame sync's adapter: nil until the sync exists (the implementation replaces nil with its adapter).
    static let deadlineSeam: (any WindowFrameSyncDeadlineSeam)? = nil

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
    static func spring(_ screen: Screen, recorder: TurnRecorder, direction: LayoutDirection = .right) async -> (moved: Bool, steps: Int) {
        screen.root.context.reduceMotionOverride = false
        let frame = screen.root.context.hosts["p2"]?.frame
        recorder.start()
        let pressed = PaneResize.press("p2", direction, model: screen.model, view: screen.root)
        var moving = true, steps = 0
        while moving, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
            steps += 1
        }
        await rest(screen)
        recorder.pause()
        return (pressed && screen.root.context.hosts["p2"]?.frame != frame, steps)
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
    static func check(_ turns: [TurnRecorder.Turn]) -> (bounds: [String], frame: [String], boundsTurns: Int, frameTurns: Int, kept: String) {
        var bounds: [String] = [], frame: [String] = []
        var boundsTurns = 0, frameTurns = 0
        // Per terminal: the committed turns in which its layer was not its pane's area (kept old bounds).
        var keptTurns = Array(repeating: 0, count: turns.first?.terminals.count ?? 0)
        var keptUntil = Array(repeating: 0.0, count: keptTurns.count)
        for turn in turns {
            var boundsFailed = false, frameFailed = false
            for (index, terminal) in turn.terminals.enumerated() {
                let name = "turn \(turn.index) (+\(text(turn.at)) ms) p\(index + 1)\(terminal.waiting ? " (its new size waits for its frame)" : "")"
                if !terminal.layer.isNear(terminal.area) {
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
        }

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
                                waiting: presenter.isWaiting(surface))
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

        static func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
    }
}
