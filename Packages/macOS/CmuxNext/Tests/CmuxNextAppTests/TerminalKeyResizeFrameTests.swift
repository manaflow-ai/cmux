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
        // Warm-up press: one-time setup is not the press under test.
        _ = PaneResize.press("p2", .left, model: screen.model, view: screen.root)
        await Self.settle(screen)
        let resizesBefore = screen.ios.map { $0.resizes.count }

        _ = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var frames: [[Sample]] = []
        var intervals: [Double] = []
        var last = ContinuousClock.now
        var still = 0
        while frames.count < 240, still < 12 {
            await Self.commit()
            let now = ContinuousClock.now
            intervals.append(Self.ms(last.duration(to: now)))
            last = now
            let sample = screen.sessions.map(Sample.init)
            if let previous = frames.last, previous.map(\.area) == sample.map(\.area), previous.map(\.layer) == sample.map(\.layer) {
                still += 1
            } else {
                still = 0
            }
            frames.append(sample)
        }
        let moving = frames.count - still
        try #require(moving >= 4, "the press moved its panes in \(moving) frames: no spring ran")
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
        let sorted = intervals.dropFirst().sorted()
        let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print("S4 key resize: \(moving) moving frames; frame interval ms p50 \(p(0.5)) p95 \(p(0.95)) max \(sorted.last ?? 0); " +
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

    /// Commits until no terminal waits for its frame and the panes rest (at most 3 s).
    static func settle(_ screen: KeyScreen) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var still = 0
        var last: [CGSize] = []
        while ContinuousClock.now < deadline, still < 12 {
            await commit()
            let now = screen.sessions.map { $0.view.bounds.size }
            still = now == last ? still + 1 : 0
            last = now
        }
    }

    static func commit() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CommitBoundary().after { _ in done.resume() }
        }
    }
}
