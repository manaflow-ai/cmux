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
/// The real path, in a window on screen: p1 | p2 in a ``LayoutRootView`` (Reduce Motion off, S3's content policy on), a
/// terminal in each, and one Ctrl-Shift-L press on p2 (`PaneResize.press`): the divider moves, so p2's LEFT edge moves
/// (the film's case: dogfood 437f5a22, px-keys-single-3k-s1r, p2's left ring on its pane edge in 14 of 50 motion frames,
/// off by -8 to +21 px in 20, cut off in 16). The test steps the spring itself, one frame per step. After each frame's
/// commit it reads, per terminal, in the committed layer tree: the surface's top-left must be on its area's top-left
/// (1 device px), and its size must be one its pane had in this press, this frame or earlier (the newest frame drawn or
/// an older one kept: never a size the pane has not had yet). After the landing each terminal shows its final size, and
/// each PTY got at most one grid for the press. It prints each frame's main time (step and layout, p50, p95, max).
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
        // Per frame and terminal (the film gate, pixel-perfect on dogfood 437f5a22: p2's left ring off its pane's left edge
        // in 36 of 50 motion frames): the surface's top-left is on its area's top-left (1 device px), and it shows a size
        // its pane had in this press, this frame or earlier (the newest frame drawn, or an older one kept until then:
        // never a size the pane has not had yet, never stretched). At the end every terminal shows its final size.
        var misplaced: [String] = []
        var unsized: [String] = []
        for index in 1..<frames.count {
            for (terminal, sample) in frames[index].enumerated() {
                let scale = sample.scale
                func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) * scale <= 1 }
                if !near(sample.topLeft.x, sample.areaTopLeft.x) || !near(sample.topLeft.y, sample.areaTopLeft.y) {
                    misplaced.append("frame \(index) p\(terminal + 1): top-left \(sample.topLeft), its area's \(sample.areaTopLeft)")
                }
                let had = frames[0...index].map { $0[terminal].area }
                if !had.contains(where: { near(sample.layer.width, $0.width) && near(sample.layer.height, $0.height) }) {
                    unsized.append("frame \(index) p\(terminal + 1): layer \(Self.text(sample.layer)), area \(Self.text(sample.area))")
                }
            }
        }
        let landed = (frames.last ?? []).enumerated().filter { _, sample in
            abs(sample.layer.width - sample.area.width) * sample.scale > 1 || abs(sample.layer.height - sample.area.height) * sample.scale > 1
        }.map { "p\($0.offset + 1): layer \(Self.text($0.element.layer)), area \(Self.text($0.element.area))" }
        // The press's grid reaches the IO through the ordered input stream: read it after the panes rest.
        await Self.settle(screen)
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let sorted = intervals.sorted()
        let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print("S4 key resize: \(steps) spring frames; main ms per frame (step + layout) p50 \(p(0.5)) p95 \(p(0.95)) max \(sorted.last ?? 0); " +
              "PTY grids per terminal \(resizes); misplaced \(misplaced.count), unsized \(unsized.count)")
        #expect(misplaced.isEmpty, "\(misplaced.count) frames showed a terminal off its pane's top-left: \(misplaced.prefix(8))")
        #expect(unsized.isEmpty, "\(unsized.count) frames showed a terminal at a size its pane had not had yet: \(unsized.prefix(8))")
        #expect(landed.isEmpty, "after the landing a terminal does not show its pane's size: \(landed)")
        #expect(resizes.allSatisfy { $0 <= 1 }, "a press resized a terminal's program more than once: \(resizes)")
        #expect(screen.mismatches.isEmpty, "turns with the layer and its frame at different sizes: \(screen.mismatches.prefix(6))")
    }

    /// One terminal in one committed frame: its surface layer's size and top-left, and its host's area size and top-left
    /// (points; top-lefts in the window's root layer, the committed model).
    struct Sample {
        var layer: CGSize
        var area: CGSize
        var topLeft: CGPoint
        var areaTopLeft: CGPoint
        var scale: CGFloat

        @MainActor init(_ session: TerminalSession) {
            let surface = session.surfaceView
            let host = session.view
            layer = surface.layer?.bounds.size ?? .zero
            area = host.surfaceSize(forHostSize: host.bounds.size)
            scale = surface.layer?.contentsScale ?? 2
            // The host is not flipped: its area's top is its bounds' maxY (an accessory strip sits at its bottom).
            func top(_ layer: CALayer?, _ rect: CGRect) -> CGPoint {
                guard let layer, let root = host.window?.contentView?.layer else { return .zero }
                let shown = layer.convert(rect, to: root)
                return CGPoint(x: shown.minX, y: root.isGeometryFlipped ? shown.minY : shown.maxY)
            }
            topLeft = top(surface.layer, surface.layer?.bounds ?? .zero)
            areaTopLeft = top(host.layer, host.layer?.bounds ?? .zero)
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
