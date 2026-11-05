import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTabs
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
/// Before: the key resize's hold (RESIZE KEYS K3) kept each surface at one size per press (S3's host follows its pane,
/// but its surface keeps the press's final size, or its start size, on the hold's still edges), so the terminal froze,
/// then jumped. Film on dogfood 437f5a22 (px-keys-single-3k-s1r): the terminal right of the divider had its left ring on
/// its pane's left edge in 14 of 50 motion frames, off by -8 to +21 px in 20, cut off in 16.
///
/// The app's own pane content (`PaneContentView`: its tab strip over its content area, which a key hold follows, FRAME
/// OWNER S1/S3) with a terminal in each of p1 | p2, in a window on screen; one Ctrl-Shift-L press on p2
/// (`PaneResize.press`): the divider moves, so p2's LEFT edge moves. The test steps the spring itself, one frame per step
/// (a display-link spring may not animate on a CI host). After each frame's commit it reads, per terminal, in the
/// committed layer tree:
/// - the surface's top-left within 1 device px of its host area's top-left;
/// - a size its pane had in this press, this frame or earlier (the newest frame drawn, or an older one kept until then:
///   never a size the pane has not had yet), and never stretched (the layer's pixels are the frame's pixels);
/// - after the landing, each terminal at its final size; each PTY at most one grid for the press.
/// It prints each frame's main time (step and layout: p50, p95, max).
///
/// It needs a window on a display (a display worker: `cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalKeyResizeFrameTests {
    @Test func aKeyResizeShowsEachTerminalAtItsPanesSizeInEveryFrameAndResizesItsProgramOnce() async throws {
        let screen = try await PaneScreen()
        defer { screen.close() }
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
        try #require(frames.contains { $0.map(\.area) != before.map(\.area) }, "the press changed no pane's area")

        var misplaced: [String] = []
        var unsized: [String] = []
        var stretched: [String] = []
        // Review of #35470 (T1): the sizes allowed include the start size, so count the frames in which each terminal
        // took a new size: a terminal that keeps one size through the spring (the defect) fails here.
        var changes = Array(repeating: 0, count: before.count)
        for index in 1..<frames.count {
            for terminal in frames[index].indices where frames[index][terminal].layer != frames[index - 1][terminal].layer {
                changes[terminal] += 1
            }
        }
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
                if let shown = sample.shownPixels, abs(sample.layer.width * scale - shown.width) > 1 || abs(sample.layer.height * scale - shown.height) > 1 {
                    stretched.append("frame \(index) p\(terminal + 1): layer \(Self.text(sample.layer)) at \(scale)x, frame \(Self.text(shown)) px")
                }
            }
        }
        // The press's grid reaches the IO through the ordered input stream: read it after the panes rest.
        await Self.settle(screen)
        let rested = screen.sessions.map(Sample.init)
        let landed = rested.enumerated().filter { _, sample in
            abs(sample.layer.width - sample.area.width) * sample.scale > 1 || abs(sample.layer.height - sample.area.height) * sample.scale > 1
        }.map { "p\($0.offset + 1): layer \(Self.text($0.element.layer)), area \(Self.text($0.element.area))" }
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let sorted = intervals.sorted()
        let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        print("S4 key resize: \(steps) spring frames; main ms per frame (step + layout) p50 \(p(0.5)) p95 \(p(0.95)) max \(sorted.last ?? 0); " +
              "PTY grids per terminal \(resizes); misplaced \(misplaced.count), unsized \(unsized.count), stretched \(stretched.count)")
        #expect(misplaced.isEmpty, "\(misplaced.count) frames showed a terminal off its pane's top-left: \(misplaced.prefix(8))")
        #expect(unsized.isEmpty, "\(unsized.count) frames showed a terminal at a size its pane had not had yet: \(unsized.prefix(8))")
        #expect(stretched.isEmpty, "\(stretched.count) frames showed a terminal's frame stretched: \(stretched.prefix(8))")
        #expect(landed.isEmpty, "after the landing a terminal does not show its pane's size: \(landed)")
        #expect(resizes.allSatisfy { $0 <= 1 }, "a press resized a terminal's program more than once: \(resizes)")
        #expect(changes.allSatisfy { $0 > 3 }, "a terminal took a new size in only \(changes) of \(steps) spring frames: it did not follow its pane")
    }

    /// Review of #35470 (F1): a terminal whose frames wait at the landing (a busy program, or one that holds its frames
    /// with synchronized output, mode 2026, as agent TUIs do) still gets one grid for the press. The size in flight at the
    /// landing is an earlier spring size; the landing's release sized the surface from it and reported its grid (the
    /// spring was over), and the newest size reported the final grid again when it went to Ghostty: final, stale, final.
    /// The grids are locked as the daemon locks them (an announced grid: a pixel resize keeps mode 2026 set).
    @Test func aTerminalWhoseFrameWaitsAtTheLandingGetsOneGridForThePress() async throws {
        let screen = try await PaneScreen()
        defer { screen.close() }
        _ = PaneResize.press("p2", .left, model: screen.model, view: screen.root)
        _ = await Self.step(screen, record: nil)
        await Self.settle(screen)
        for (session, io) in zip(screen.sessions, screen.ios) {
            let grid = try #require(session.surfaceView.fittedGrid, "a terminal fits no grid at rest")
            io.send(.resize(cols: grid.columns, rows: grid.rows))
        }
        // p1 holds its frames from here. Ghostty ends a hold 1 s after the program's last `ESC[?2026h`, so the spring
        // below sends it again in each frame.
        let hold = Data("\u{1b}[?2026h".utf8)
        screen.ios[0].send(.output(hold))
        await Self.settle(screen)
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        let resizesBefore = screen.ios.map { $0.resizes.count }

        _ = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var steps = 0, moving = true, waitedInSpring = 0, waitingAtLanding = false
        while moving, steps < 240 {
            screen.ios[0].send(.output(hold))
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            if presenter.isWaiting(screen.sessions[0].surfaceView) { waitedInSpring += 1 }
            if !moving { waitingAtLanding = presenter.isWaiting(screen.sessions[0].surfaceView) }
            await Self.commit()
            steps += 1
        }
        try #require(steps >= 4, "the press's spring ran \(steps) frames: no spring ran")
        try #require(waitedInSpring > 1, "p1's sizes waited in \(waitedInSpring) of \(steps) frames: p1 did not hold its frames")
        try #require(waitingAtLanding, "p1 had no size in flight at the landing: the case under test did not happen")
        screen.ios[0].send(.output(Data("\u{1b}[?2026l".utf8)))
        await Self.settle(screen)
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let grids = screen.ios[0].resizes.suffix(resizes[0]).map { "\($0.columns)x\($0.rows)" }
        #expect(resizes.allSatisfy { $0 <= 1 }, "a press resized a terminal's program more than once: \(resizes) (p1: \(grids))")
    }

    /// One terminal in one committed frame: its surface layer's size and top-left, its host's area size and top-left
    /// (points; top-lefts in the window's root layer, the committed model), and the size of the frame it shows (px).
    struct Sample {
        var layer: CGSize
        var area: CGSize
        var topLeft: CGPoint
        var areaTopLeft: CGPoint
        var shownPixels: CGSize?
        var scale: CGFloat

        @MainActor init(_ session: TerminalSession) {
            let surface = session.surfaceView
            let host = session.view
            layer = surface.layer?.bounds.size ?? .zero
            area = host.surfaceSize(forHostSize: host.bounds.size)
            scale = surface.layer?.contentsScale ?? 2
            shownPixels = surface.presentedFrame.map { CGSize(width: $0.width, height: $0.height) }
            // The host is not flipped: its area's top is its bounds' maxY (an accessory strip sits at its bottom).
            func top(_ layer: CALayer?) -> CGPoint {
                guard let layer, let root = host.window?.contentView?.layer else { return .zero }
                let shown = layer.convert(layer.bounds, to: root)
                return CGPoint(x: shown.minX, y: root.isGeometryFlipped ? shown.minY : shown.maxY)
            }
            topLeft = top(surface.layer)
            areaTopLeft = top(host.layer)
        }
    }

    /// p1 | p2 in a window on screen, each pane the app's `PaneContentView` with a terminal in its content area; the
    /// switch on, Reduce Motion off, the spring stepped by the test.
    final class PaneScreen {
        final class Panes: LayoutPaneContentProvider {
            let reveal: LaunchReveal = {
                let reveal = LaunchReveal()
                reveal.markAllReady()
                return reveal
            }()
            var views: [PaneID: PaneContentView] = [:]

            func makeContentView(for pane: PaneID) -> NSView {
                let tab = TabItem(id: TabID("tab-\(pane.rawValue)"), title: "zsh")
                let view = PaneContentView(stripModel: TabStripModel(tabs: [tab], selectedID: tab.id), reveal: reveal)
                views[pane] = view
                return view
            }
        }

        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var sessions: [TerminalSession] = []
        var ios: [ScriptedTerminalIO] = []
        private let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded() // sync-layout: the panes exist before their terminals attach
            root.layoutSubtreeIfNeeded() // sync-layout: what joined the window in that pass lays out in this one
            root.driver.isManual = true
            let on = TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(true))
            if on != .bool(true) { close() }
            try #require(on == .bool(true), "the switch motion.frameOwner.terminals is not registered")
            let line = String(repeating: "y", count: 40)
            let text = Array(repeating: line, count: 400).joined(separator: "\r\n")
            for pane: PaneID in ["p1", "p2"] {
                let io = ScriptedTerminalIO()
                let session = TerminalSession(io: io)
                ios.append(io)
                guard session.surfaceView.surface != nil, let content = provider.views[pane] else {
                    close()
                    try #require(Bool(false), "libghostty created no surface, or pane \(pane) has no content")
                    return
                }
                _ = content.show(session.view)
                content.layoutSubtreeIfNeeded() // sync-layout: the attach's own layout pass
                io.send(.output(Data(text.utf8)))
                sessions.append(session)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, sessions.contains(where: { $0.surfaceView.presentedFrame == nil }) {
                await TerminalKeyResizeFrameTests.commit()
            }
            let drawn = !sessions.contains { $0.surfaceView.presentedFrame == nil }
            if !drawn { close() }
            try #require(drawn, "a terminal never showed its first frame")
        }

        func close() {
            root.driver.isManual = false
            for io in ios { io.finish() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, nil)
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
    static func step(_ screen: PaneScreen, record: (([Sample]) -> Void)?) async -> (Int, [Double]) {
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
    static func settle(_ screen: PaneScreen) async {
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
