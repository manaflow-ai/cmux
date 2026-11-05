import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// cmux-ad m6 (Lawrence on dogfood 363e39f2: "tabbar moves smoothly on ctrl shift hjkl but browsers/terminals do not
/// anymore"), part (a) for terminals, with `motion.frameOwner.terminals` on. The contract of a key resize: in EVERY frame
/// each terminal shows pixels at its pane's size in that frame, or the previous frame's (clipped and anchored top-left,
/// never stretched, never a background gap). cmux-ad m18: the PROGRAM's grid (the PTY's size) follows the view's grid at
/// most once per 25 ms, the newest (Ghostty.app's rule), and ends at the landing's grid; m6 sent one grid per press.
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
/// - after the landing, each terminal at its final size; each PTY at most one grid per 25 ms of the press (plus the
///   landing's flush), the last its view's grid.
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
        let pressed = ContinuousClock.now
        _ = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var frames: [[Sample]] = [before]
        let (steps, intervals) = await Self.step(screen) { frames.append($0) }
        let windows = Self.coalescingWindows(since: pressed)
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
        #expect(resizes.allSatisfy { $0 <= windows }, "a press resized a terminal's program more than once per 25 ms (\(windows) windows): \(resizes)")
        let ends = Self.ptyEndsAtItsViewsGrid(screen)
        #expect(ends.isEmpty, "a PTY does not end at its view's grid: \(ends)")
        #expect(changes.allSatisfy { $0 > 3 }, "a terminal took a new size in only \(changes) of \(steps) spring frames: it did not follow its pane")
    }

    /// Review of #35470 (F1): a terminal whose frames wait at the landing (a busy program, or one that holds its frames
    /// with synchronized output, mode 2026, as agent TUIs do). The landing's release once sized the surface from a stale
    /// size and reported its grid, then the final grid again: final, stale, final. cmux-ad m18 replaces "one grid per
    /// press" with the coalescer's rule: its PTY gets at most one grid per 25 ms window of the press (plus the landing's
    /// flush), and the last grid is its view's grid at rest. With no keep (m18), a frame held by mode 2026 lands late (its
    /// new bounds with the last frame) instead of waiting with old bounds. The grids are locked as the daemon locks them
    /// (an announced grid: a pixel resize keeps mode 2026 set).
    @Test func aTerminalWhoseFrameIsLateAtTheLandingEndsAtTheLandingsGrid() async throws {
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

        let pressed = ContinuousClock.now
        _ = PaneResize.press("p2", .right, model: screen.model, view: screen.root)
        var steps = 0, moving = true, waitedInSpring = 0, waitingAtLanding = false
        while moving, steps < 240 {
            screen.ios[0].send(.output(hold))
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            let p1 = screen.sessions[0].surfaceView
            await Self.commit() // the frame's pass and commit: a held frame lands late there
            if presenter.isWaiting(p1) || presenter.isLate(p1) { waitedInSpring += 1 }
            if !moving { waitingAtLanding = presenter.isWaiting(p1) || presenter.isLate(p1) }
            steps += 1
        }
        try #require(steps >= 4, "the press's spring ran \(steps) frames: no spring ran")
        try #require(waitedInSpring > 1, "p1's frames were late in \(waitedInSpring) of \(steps) frames: p1 did not hold its frames")
        try #require(waitingAtLanding, "p1's frame was not late at the landing: the case under test did not happen")
        screen.ios[0].send(.output(Data("\u{1b}[?2026l".utf8)))
        await Self.settle(screen)
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        let grids = screen.ios[0].resizes.suffix(resizes[0]).map { "\($0.columns)x\($0.rows)" }
        let windows = Self.coalescingWindows(since: pressed)
        #expect(resizes.allSatisfy { $0 <= windows }, "a press resized a terminal's program more than once per 25 ms (\(windows) windows): \(resizes) (p1: \(grids))")
        let ends = Self.ptyEndsAtItsViewsGrid(screen)
        #expect(ends.isEmpty, "a PTY does not end at its view's grid: \(ends)")
    }

    /// cmux-ad m14 (a P0 from Lawrence): in every frame each terminal shows pixels drawn at its pane's size, and its
    /// program's grid changes at most once per press. pixel-perfect's films of a key spring with the switch on (jjk-3kz:
    /// 75 frames ON, 77 OFF) showed two failures for a terminal whose prompt is low:
    /// - F2: a pane a press grows kept its surface at the press's final size on its bottom edge (the low prompt's bottom
    ///   hold), taller than the pane, so its top rows were cut for the whole spring;
    /// - H3: a pane that shrinks drew the owner's grid from its top-left, so its last rows, the prompt with them, were cut
    ///   until the owner announced the new grid, and then that grid was drawn padded.
    ///
    /// The terminal must draw, in each frame, the grid its size fits: Ghostty's reflow preview reflows a copy of the
    /// terminal to that grid, and the reflow keeps the cursor row in view (rows that shrink lose the blank rows below the
    /// cursor, then the top rows go to history; rows that grow pull history down while the cursor is on the last row).
    ///
    /// p1 over p2, each with history and its prompt on its last row, an IO that announces each grid its view reports,
    /// as the daemon does (``AnnouncingTerminalIO``, MANUAL_MIRROR), the switch on. Ctrl-Shift-J on p1 (p1 grows down, p2
    /// shrinks), Ctrl-Shift-K (p1 shrinks, p2 grows up), and J, J, K two frames apart. Each frame's sizes land with their
    /// own frames before the next frame (the test waits for them). After each frame, per terminal:
    /// - the surface's frame is its area's (never taller, never on another edge);
    /// - the grid Ghostty drew is the grid the shown frame's pixel size fits.
    /// After the landing, each terminal rests at its area with the owner's grid drawn and its prompt on the last row,
    /// and its program got at most one grid per press.
    @Test(arguments: [[LayoutDirection.down], [.up], [.down, .down, .up]])
    func aLowPromptTerminalDrawsTheGridItsPaneFitsInEveryFrameOfAKeySpring(presses: [LayoutDirection]) async throws {
        let screen = try await PaneScreen(axis: .vertical, announcesGrids: true)
        defer { screen.close() }
        // The prompt on the last row, under the history.
        for io in screen.ios { io.send(.output(Data("\r\n$ ".utf8))) }
        let low = await Self.commits(screen) { $0.sessions.allSatisfy(Self.restsWithItsPromptLow) }
        try #require(low, "SETUP: a terminal does not rest with its prompt on the last row of the grid its owner announced")
        await Self.settle(screen)
        let resizesBefore = screen.ios.map { $0.resizes.count }
        let pressed = ContinuousClock.now

        var frames: [[GridSample]] = []
        /// This frame's sizes land with their own frames (at most 2 s), then each terminal is sampled.
        func sampleFrame() async {
            _ = await Self.commits(screen, seconds: 2) { $0.sessions.allSatisfy(Self.showsItsOwnFrame) }
            frames.append(screen.sessions.map(GridSample.init))
        }
        var steps = 0
        for (index, direction) in presses.enumerated() {
            try #require(PaneResize.press("p1", direction, model: screen.model, view: screen.root),
                         "Ctrl-Shift-\(direction) on p1 moved nothing")
            // A press before the last lands two frames later, a key repeat apart; the last runs to its landing.
            let last = index == presses.count - 1
            var moving = true, stepped = 0
            while moving, stepped < (last ? 240 : 2) {
                moving = await Self.stepFrame(screen).moving
                await sampleFrame()
                stepped += 1
            }
            try #require(last || moving, "press \(index + 1) landed before the next press")
            steps += stepped
        }
        // The landing's release.
        for _ in 0..<6 {
            await Self.commit()
            await sampleFrame()
        }
        try #require(steps >= 4, "the presses' spring ran \(steps) frames: no spring ran")

        var off: [String] = [], undrawn: [String] = [], unshown: [String] = []
        for (index, frame) in frames.enumerated() {
            for (terminal, sample) in frame.enumerated() {
                let label = "frame \(index + 1) p\(terminal + 1)"
                if !sample.onItsArea { off.append("\(label): surface \(sample.surface), its area \(sample.area)") }
                guard sample.showsItsOwnFrame else {
                    unshown.append(label)
                    continue
                }
                if sample.drawn == nil || sample.drawn != sample.fits {
                    undrawn.append("\(label): drew \(Self.text(sample.drawn)), its frame fits \(Self.text(sample.fits))")
                }
            }
        }
        await Self.settle(screen)
        var rested: [String] = []
        for (index, session) in screen.sessions.enumerated() {
            let sample = GridSample(session), grids = session.drawnAndOwnerGrid
            if !sample.onItsArea { rested.append("p\(index + 1): surface \(sample.surface), its area \(sample.area)") }
            if !Self.restsWithItsPromptLow(session) || sample.fits != grids.owner {
                rested.append("p\(index + 1): drew \(Self.text(grids.drawn)), owner's \(Self.text(grids.owner)), fits \(Self.text(sample.fits)), prompt not on its last row")
            }
        }
        let resizes = zip(screen.ios.map { $0.resizes.count }, resizesBefore).map { $0 - $1 }
        print("m14 low prompt, presses \(presses): \(steps) spring frames; off their area \(off.count), drawn grid off \(undrawn.count), " +
              "frame not shown \(unshown.count); PTY grids per terminal \(resizes)")
        #expect(off.isEmpty, "\(off.count) frames showed a terminal off its area (a hold): \(off.prefix(6))")
        #expect(undrawn.isEmpty, "\(undrawn.count) frames drew a grid other than the one the terminal's size fits (its prompt cut or padded): \(undrawn.prefix(6))")
        #expect(unshown.isEmpty, "\(unshown.count) frames' sizes never showed their own frames: \(unshown.prefix(6))")
        #expect(rested.isEmpty, "after the landing: \(rested)")
        let windows = Self.coalescingWindows(since: pressed)
        #expect(resizes.allSatisfy { $0 <= windows }, "the presses resized a terminal's program more than once per 25 ms (\(windows) windows): \(resizes)")
    }

    /// One terminal after a frame's sizes landed: its surface's frame and its area (host points: the host's area under
    /// its top edge, less a legacy scroller's strip), whether it shows the frame drawn at its size, the grid Ghostty drew
    /// and the grid the shown frame's pixel size fits.
    struct GridSample {
        var surface: CGRect
        var area: CGRect
        var scale: CGFloat
        var showsItsOwnFrame: Bool
        var drawn: TerminalGridSize?
        var fits: TerminalGridSize?

        @MainActor init(_ session: TerminalSession) {
            let view = session.surfaceView, host = session.view
            let size = host.surfaceSize(forHostSize: host.bounds.size)
            surface = view.frame
            area = CGRect(x: host.bounds.minX, y: host.bounds.maxY - size.height, width: size.width, height: size.height)
            scale = view.layer?.contentsScale ?? 2
            showsItsOwnFrame = TerminalKeyResizeFrameTests.showsItsOwnFrame(session)
            drawn = session.drawnAndOwnerGrid.drawn
            var columns: UInt16 = 0, rows: UInt16 = 0
            if let ghostty = view.surface, let frame = view.presentedFrame,
               ghostty_surface_fit_grid(ghostty, UInt32(frame.width), UInt32(frame.height), &columns, &rows) {
                fits = TerminalGridSize(columns: Int(columns), rows: Int(rows))
            }
        }

        /// The surface's frame is its area's, within a device pixel on each edge.
        var onItsArea: Bool {
            func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) * scale <= 1 }
            return near(surface.minX, area.minX) && near(surface.maxX, area.maxX) && near(surface.minY, area.minY)
                && near(surface.maxY, area.maxY)
        }
    }

    /// Whether `session`'s surface shows the frame drawn at its size: no size waits for its frame, and its layer and
    /// the frame it shows have one pixel size.
    static func showsItsOwnFrame(_ session: TerminalSession) -> Bool {
        let view = session.surfaceView
        if let window = view.window, TerminalFramePresenter.forWindow(window).isWaiting(view) { return false }
        guard let layer = view.layer, let frame = view.presentedFrame else { return false }
        let scale = layer.contentsScale
        return Int((layer.bounds.width * scale).rounded()) == frame.width && Int((layer.bounds.height * scale).rounded()) == frame.height
    }

    /// Whether `session` rests with its prompt low: its owner announced the grid its view fits, the last frame drew that
    /// grid, and the cursor is on its last row.
    static func restsWithItsPromptLow(_ session: TerminalSession) -> Bool {
        let grids = session.drawnAndOwnerGrid
        guard let surface = session.surfaceView.surface, let owner = grids.owner, owner == session.surfaceView.fittedGrid,
              grids.drawn == owner else { return false }
        var metrics = ghostty_surface_grid_metrics_s()
        return ghostty_surface_grid_metrics(surface, &metrics) && metrics.cursor_in_viewport && !metrics.alternate_screen
            && Int(metrics.cursor_row) == Int(metrics.rows) - 1
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

    /// p1 | p2 (`axis` .vertical: p1 over p2) in a window on screen, each pane the app's `PaneContentView` with a terminal
    /// in its content area; the switch on, Reduce Motion off, the spring stepped by the test. `announcesGrids`: each
    /// terminal's IO answers as the daemon does (``AnnouncingTerminalIO``); else it announces nothing.
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

        init(axis: SplitAxis = .horizontal, announcesGrids: Bool = false) async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
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
                let owner: any TerminalIO = announcesGrids ? AnnouncingTerminalIO(io) : io
                let session = TerminalSession(io: owner)
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

    /// The most grids one terminal's PTY may get from `start` to now under m18's coalescing: one per 25 ms window
    /// (``TerminalGridReportCoalescer/defaultInterval``) begun in that time, plus the landing's flush.
    static func coalescingWindows(since start: ContinuousClock.Instant) -> Int {
        let ms = Self.ms(start.duration(to: .now))
        return Int((ms / 25).rounded(.up)) + 1
    }

    /// The terminals whose PTY's last grid (as their IO recorded it) is not the grid their view fits now.
    static func ptyEndsAtItsViewsGrid(_ screen: PaneScreen) -> [String] {
        zip(screen.sessions, screen.ios).enumerated().compactMap { index, pair in
            let (session, io) = pair
            guard let fitted = session.surfaceView.fittedGrid, let last = io.resizes.last else { return nil }
            return last.columns == fitted.columns && last.rows == fitted.rows
                ? nil : "p\(index + 1): PTY \(last.columns)x\(last.rows), view \(text(fitted))"
        }
    }

    static func text(_ grid: TerminalGridSize?) -> String { grid.map { "\($0.columns)x\($0.rows)" } ?? "none" }

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
            let frame = await stepFrame(screen)
            moving = frame.moving
            intervals.append(frame.ms)
            record?(screen.sessions.map(Sample.init))
            steps += 1
        }
        for _ in 0..<6 {
            await commit()
            record?(screen.sessions.map(Sample.init))
        }
        return (steps, intervals)
    }

    /// One frame of the spring: the step, its layout pass and its commit. Returns whether the spring still moves and the
    /// frame's main time (step and layout, ms).
    static func stepFrame(_ screen: PaneScreen) async -> (moving: Bool, ms: Double) {
        let started = ContinuousClock.now
        let moving = screen.root.advanceFrame(1.0 / 120)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        let elapsed = ms(started.duration(to: .now))
        await commit()
        return (moving, elapsed)
    }

    /// Commits until `done` holds for `screen`, checked before each commit (at most `seconds`); whether it held.
    static func commits(_ screen: PaneScreen, seconds: Int = 10, until done: (PaneScreen) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !done(screen) {
            guard ContinuousClock.now < deadline else { return false }
            await commit()
        }
        return true
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

/// A daemon terminal's IO over a ``ScriptedTerminalIO``, which records what it is asked: each grid the view reports
/// becomes the PTY's grid and is announced back in the stream (`.resize`), as the cmux-tui daemon does for a visible
/// view that holds geometry. So the view's grid is applied (``TerminalIO/appliesViewGrid(reporting:)``) and the surface
/// draws its reflow preview until the announcement. MANUAL_MIRROR, as a daemon terminal: the announced grid locks the
/// mirror and clips or pads its lines; the mirror never reflows on its own.
nonisolated final class AnnouncingTerminalIO: TerminalIO {
    let scripted: ScriptedTerminalIO

    init(_ scripted: ScriptedTerminalIO) {
        self.scripted = scripted
    }

    var events: AsyncStream<TerminalIOEvent> { scripted.events }
    var answersTerminalQueries: Bool { scripted.answersTerminalQueries }

    func write(_ data: Data) async {
        await scripted.write(data)
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        await scripted.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        scripted.send(.resize(cols: cols, rows: rows))
    }

    @MainActor func appliesViewGrid(reporting: Bool) -> Bool { true }
}
