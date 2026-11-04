import AppKit
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// cmux-ad m6 (Lawrence on dogfood 363e39f2: "tabbar moves smoothly on ctrl shift hjkl but browsers/terminals do not
/// anymore"), part (a) for terminals, with `motion.frameOwner.terminals` on. The contract of a key resize: in EVERY frame
/// each terminal shows pixels at its pane's size in that frame, or the previous frame's (clipped and anchored top-left,
/// never stretched, never a background gap); the PROGRAM's grid (the PTY's size) changes at most once per press. Pixels
/// per frame; program size per press.
///
/// Before: the key resize's hold (RESIZE KEYS K3, `TerminalSurfaceView.restAt`) held each surface at the press's final
/// size for the whole spring, so a terminal's pixels changed size once per press while its pane (and, with FRAME OWNER
/// S3, its host and tab strip) moved every frame: the content froze, then jumped.
///
/// The real path, in a window on screen: p1 | p2 in a ``LayoutRootView`` with its spring running (Reduce Motion off, S3's
/// content policy on), a terminal in each, and one Ctrl-Shift-H press (`PaneResize.press`). After each Core Animation
/// commit of the spring it reads, per terminal, its surface layer's size and its host's area size (the size its pane gives
/// it in that frame). Each frame's layer size must be within 1 device pixel of that frame's area size, or of the previous
/// frame's. Each terminal's PTY gets at most one new grid for the press. It also prints the spring's frame intervals
/// (p50, p95, max) and the main-thread time of each frame's terminal placement.
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalKeyResizeFrameTests {
    typealias KeyScreen = TerminalSurfaceCommitSizeTests.KeyScreen

    @Test func aKeyResizeShowsEachTerminalAtItsPanesSizeInEveryFrameAndResizesItsProgramOnce() async throws {
        let screen = try await KeyScreen()
        defer { screen.close() }
        // A spring, as a person sees it (KeyScreen pins Reduce Motion on), with S3's containers following their panes.
        screen.root.context.reduceMotionOverride = false
        screen.root.context.contentPolicyOverride = true
        // The test is the clock, as in TabStripFollowsPaneTickTests: one spring frame per step (1/120 s), its layout
        // pass, then that frame's Core Animation commit. A display-link spring may not animate on a CI host (its
        // animation speed setting); stepping it shows every frame the spring has.
        screen.root.driver.isManual = true
        defer { screen.root.driver.isManual = false }
        // Warm-up press: one-time setup is not the press under test.
        _ = PaneResize.press("p2", .left, model: screen.model, view: screen.root)
        _ = await Self.step(screen, record: nil)
        await Self.settle(screen)
        let resizesBefore = screen.ios.map { $0.resizes.count }

        let before = screen.sessions.map(Sample.init)
        _ = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var frames: [[Sample]] = [before]
        let (steps, intervals) = await Self.step(screen) { frames.append($0) }
        try #require(steps >= 4, "the press's spring ran \(steps) frames: no spring ran")
        var wrong: [String] = []
        for index in 1..<frames.count {
            for (terminal, sample) in frames[index].enumerated() {
                let previousArea = frames[index - 1][terminal].area
                let scale = sample.scale
                func near(_ size: CGSize) -> Bool {
                    abs(sample.layer.width - size.width) * scale <= 1 && abs(sample.layer.height - size.height) * scale <= 1
                }
                if !near(sample.area) && !near(previousArea) {
                    wrong.append("frame \(index) p\(terminal + 1): layer \(Self.text(sample.layer)), pane area \(Self.text(sample.area)) (previous \(Self.text(previousArea)))")
                }
            }
        }
        // The press's grid reaches the IO through the ordered input stream: read it after the panes rest.
        await Self.settle(screen)
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let sorted = intervals.sorted()
        let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print("S4 key resize: \(steps) spring frames; main ms per frame (step + layout) p50 \(p(0.5)) p95 \(p(0.95)) max \(sorted.last ?? 0); " +
              "PTY grids per terminal \(resizes); wrong frames \(wrong.count)")
        #expect(wrong.isEmpty, "\(wrong.count) frames showed a terminal at a size its pane did not have then or one frame before: \(wrong.prefix(8))")
        #expect(resizes.allSatisfy { $0 <= 1 }, "a press resized a terminal's program more than once: \(resizes)")
        #expect(screen.mismatches.isEmpty, "turns with the layer and its frame at different sizes: \(screen.mismatches.prefix(6))")
    }

    /// One terminal in one committed frame: its surface layer's size and its host's area (points).
    struct Sample {
        var layer: CGSize
        var area: CGSize
        var scale: CGFloat

        @MainActor init(_ session: TerminalSession) {
            let surface = session.surfaceView
            layer = surface.layer?.bounds.size ?? .zero
            area = session.view.surfaceSize(forHostSize: session.view.bounds.size)
            scale = surface.layer?.contentsScale ?? 2
        }
    }

    static func text(_ size: CGSize) -> String { "\(size.width)x\(size.height)" }

    static func ms(_ duration: Duration) -> Double {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return (ms * 100).rounded() / 100
    }

    /// Steps the spring to its landing, one frame per step: the step, its layout pass, its commit (`record` gets each
    /// committed frame), then 6 commits for the landing's release. Returns the frames stepped and each frame's main
    /// time (step and layout, ms).
    static func step(_ screen: KeyScreen, record: (([Sample]) -> Void)?) async -> (Int, [Double]) {
        var intervals: [Double] = []
        var moving = true
        var steps = 0
        while moving, steps < 240 {
            let started = ContinuousClock.now
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            intervals.append(ms(started.duration(to: .now)))
            await commit()
            record?(screen.sessions.map(Sample.init))
            steps += 1
        }
        for _ in 0..<6 {
            await commit()
            record?(screen.sessions.map(Sample.init))
        }
        return (steps, intervals)
    }

    /// Commits until the panes and their terminals have not changed for 300 ms of wall-clock time (at most 3 s).
    static func settle(_ screen: KeyScreen) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var last: [CGSize] = []
        var changed = ContinuousClock.now
        while ContinuousClock.now < deadline, changed.duration(to: .now) < .milliseconds(300) {
            await commit()
            let now = screen.sessions.flatMap { [$0.view.bounds.size, $0.surfaceView.layer?.bounds.size ?? .zero] }
            if now != last { (last, changed) = (now, .now) }
        }
    }

    static func commit() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CommitBoundary().after { _ in done.resume() }
        }
    }
}
