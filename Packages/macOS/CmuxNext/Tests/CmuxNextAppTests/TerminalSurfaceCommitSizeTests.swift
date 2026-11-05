import AppKit
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import GhosttyNextKit
import IOSurface
import Testing

/// FRAME OWNER REFACTOR S4 (terminals ready-or-keep, switch `motion.frameOwner.terminals`): for every terminal, in
/// every commit, the layer's size and its pixels change together, or neither changes. Films P2: a new-size frame of a
/// host-sized Ghostty surface came 2-4 refreshes after its view's new bounds, so those commits showed the old frame in
/// the new bounds (cropped or beside a gap), and two terminals landed 2 refreshes apart.
///
/// A real Ghostty surface (MANUAL_MIRROR, the daemon's mode) in a window whose layout resizes it in AppKit's display
/// cycle, as a pane's layout does. An observer right after Core Animation's commit (``CommitBoundary/order``) reads, at
/// the end of every main run-loop turn, the surface layer's bounds in pixels and the size of the IOSurface it shows.
/// No clock and no sleep: the test waits for commits.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)))
struct TerminalSurfaceCommitSizeTests {
    /// Narrowing steps of a drag: the terminal's width at each step, in points (whole pixels at 1x and 2x).
    static let widths: [CGFloat] = [580, 560, 540, 520, 500, 480]

    /// A divider drag's sizes, one layout per step: no turn ever ends with the layer's bounds and the shown frame at
    /// different sizes, and the last size shows its own frame.
    @Test func aResizeCommitNeverCarriesALayerSizeOtherThanItsIOSurface() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        for width in Self.widths {
            await fixture.resize(to: width)
            await fixture.commits(2)
        }
        let last = try #require(Self.widths.last)
        let landed = await fixture.waitShown(width: last)
        #expect(landed, "the last size never showed its own frame (shown \(fixture.shownPixels.map { "\($0)" } ?? "nothing"))")
        #expect(fixture.samples > 0, "no turn was sampled")
        #expect(fixture.mismatches.isEmpty,
                "\(fixture.mismatches.count) turns ended with the layer at one size and its frame at another: \(fixture.mismatches.prefix(8))")
        let stats = TerminalFramePresenter.forWindow(fixture.window).stats
        #expect(stats.presented > 0, "presenter: \(stats)")
    }

    /// Its window moved to a display of another scale (1x and 2x): the terminal keeps its layer's scale and its frame
    /// until the frame drawn at the new scale is ready, and both change in that one commit (Codex review of
    /// b9bafbda1e0: the new `contentsScale` went to the layer at once, so the old frame showed at the new scale for
    /// 1-4 refreshes). The landing's commit is then reported, so output goes to the screen off the main thread again.
    @Test func aNewDisplayScaleLandsWithTheFrameDrawnAtIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let view = fixture.session.surfaceView
        let old = try #require(view.layer?.contentsScale, "the terminal has no layer")
        let new: CGFloat = old == 2 ? 1 : 2
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        let presentedBefore = presenter.stats.presented
        // What AppKit does when the window moves to a display of another scale.
        view.backingScaleOverride = new
        view.viewDidChangeBackingProperties()
        let landed = await fixture.waitShown(width: 600, scale: new)
        #expect(landed, "the frame drawn at \(new)x never showed (shown \(fixture.shownPixels.map { "\($0)" } ?? "nothing"))")
        #expect(view.layer?.contentsScale == new, "the layer's scale is \(view.layer?.contentsScale ?? 0), the display's is \(new)")
        #expect(fixture.mismatches.isEmpty,
                "\(fixture.mismatches.count) turns ended with the layer at one size and its frame at another: \(fixture.mismatches.prefix(8))")
        #expect(presenter.stats.presented > presentedBefore, "the new scale's frame did not come through the presenter: \(presenter.stats)")
        // The landing's commit is reported: output at the new scale goes to the screen off the main thread again.
        let offMain = fixture.offMainPresents
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var line = 0
        while ContinuousClock.now < deadline, fixture.offMainPresents == offMain {
            fixture.io.send(.output(Data("\r\nscale \(line)".utf8)))
            line += 1
            await fixture.commits(1)
        }
        #expect(fixture.offMainPresents > offMain,
                "no frame went to the screen off the main thread after the new scale landed (host_off_main_presents stays \(offMain))")
    }

    /// FRAME OWNER S3 + S4 in a key resize (cmux-ad m6; first found as S4 defect (b), red step d509169a15477622073341e5):
    /// the host follows its pane (S3, ``PaneMotionHoldFollowing``) on a hold that keeps the pane's trailing or bottom
    /// edge still, and the pane's size changes while the terminal's new size waits for its frame. The kept frame is
    /// anchored top-left (the lead's m6 contract: the previous size's frame, clipped and anchored top-left, never
    /// stretched): its top-left stays on the area's top-left, and the new size lands with its frame. Before, the kept
    /// frame rode another edge than the pane's content did for the refreshes until the new size showed.
    @Test func aKeptFrameStaysOnTheEdgesItsHoldNames() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = fixture.session.view
        let surface = fixture.session.surfaceView
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        let rest = surface.frame
        try #require(rest.width > 200 && rest.height > 100, "the terminal's rest frame is \(rest)")

        // A trailing hold: the pane's trailing edge stands still and the pane narrows (its left edge moves).
        host.followPaneMotion(PaneMotionHold(trailing: true, bottom: false), heldSize: host.bounds.size)
        fixture.layoutNow()
        fixture.container.terminalWidth -= 80
        fixture.layoutNow()
        try #require(presenter.isWaiting(surface), "the narrower size did not wait for its frame (frame \(surface.frame))")
        #expect(surface.frame.size == rest.size, "while its new size waits the terminal is \(surface.frame.size), it keeps \(rest.size)")
        #expect(surface.frame.minX == host.bounds.minX && surface.frame.maxY == host.bounds.maxY,
                "a trailing hold: the kept frame \(surface.frame) is not anchored on its area's top-left \(host.bounds)")
        let narrowShown = await fixture.waitShown(width: rest.width - 80)
        #expect(narrowShown, "the narrower size never showed its own frame")
        #expect(surface.frame == CGRect(x: rest.minX, y: rest.minY, width: rest.width - 80, height: rest.height),
                "the landed frame is \(surface.frame)")
        host.followPaneMotion(nil, heldSize: nil)
        fixture.container.terminalWidth += 80
        fixture.layoutNow()
        let restShown = await fixture.waitShown(width: rest.width)
        #expect(restShown, "the rest size never showed again")

        // A bottom hold: the pane's bottom edge stands still and the pane gets shorter (its top edge moves).
        host.followPaneMotion(PaneMotionHold(trailing: false, bottom: true), heldSize: host.bounds.size)
        fixture.layoutNow()
        fixture.container.terminalHeight -= 40
        fixture.layoutNow()
        try #require(presenter.isWaiting(surface), "the shorter size did not wait for its frame (frame \(surface.frame))")
        #expect(surface.frame.size == rest.size, "while its new size waits the terminal is \(surface.frame.size), it keeps \(rest.size)")
        #expect(surface.frame.minX == host.bounds.minX && surface.frame.maxY == host.bounds.maxY,
                "a bottom hold: the kept frame \(surface.frame) is not anchored on its area's top-left \(host.bounds)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, presenter.isWaiting(surface) { await fixture.commits(1) }
        #expect(!presenter.isWaiting(surface), "the shorter size still waits for its frame after 2 s")
        #expect(surface.frame == CGRect(x: rest.minX, y: rest.minY, width: rest.width, height: rest.height - 40),
                "the landed frame is \(surface.frame)")
        host.followPaneMotion(nil, heldSize: nil)
        fixture.container.terminalHeight += 40
        fixture.layoutNow()
        #expect(fixture.mismatches.isEmpty,
                "\(fixture.mismatches.count) turns ended with the layer at one size and its frame at another: \(fixture.mismatches.prefix(8))")
    }

    /// Switch on, a window that draws: a host that follows its pane gives its surface the area's frame whatever hold the
    /// surface has (a low prompt's bottom hold, as a join sets one before its area hands it the follow), so a frame kept
    /// while a new size waits rides the area's top-left like the content of every other frame.
    /// - Review of #35914 at 03c050e893f (H1): a bottom hold not taller than its area kept the hold's bottom edge; as the
    ///   area got shorter its top rows were cut and the text moved up by the height the area lost, then down again when
    ///   the frame landed.
    /// - cmux-ad m14: a bottom hold taller than its area kept the surface on the bottom edge (F2): the surface was taller
    ///   than its pane and its top rows were cut. Now it takes the area's frame too and asks for no other size; its reflow
    ///   preview keeps the prompt in view at the area's grid (TerminalKeyResizeFrameTests).
    @Test func aFollowedSurfaceTakesItsAreasFrameWhateverItsHold() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let host = fixture.session.view
        let surface = fixture.session.surfaceView
        let presenter = TerminalFramePresenter.forWindow(fixture.window)
        let rest = surface.frame
        try #require(rest.width > 200 && rest.height > 100, "the terminal's rest frame is \(rest)")

        // The pane's top edge stands still; the surface has a bottom hold below the area's height (a low prompt's hold),
        // then the pane gets shorter (a reverse press) while that size waits for its frame.
        host.followPaneMotion(PaneMotionHold(trailing: false, bottom: false), heldSize: host.bounds.size)
        host.holdSurface(size: CGSize(width: rest.width, height: rest.height - 60), anchor: .bottom)
        fixture.layoutNow()
        #expect(surface.frame == rest, "a hold not taller than the area: the surface is \(surface.frame), its area \(rest)")
        fixture.container.terminalHeight -= 30
        fixture.layoutNow()
        try #require(presenter.isWaiting(surface), "the shorter size did not wait for its frame (frame \(surface.frame))")
        #expect(surface.frame.size == rest.size, "while its new size waits the terminal is \(surface.frame.size), it keeps \(rest.size)")
        #expect(surface.frame.minX == host.bounds.minX && surface.frame.maxY == host.bounds.maxY,
                "the kept frame \(surface.frame) is not on its area's top-left \(host.bounds): its text moved with the bottom edge")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, presenter.isWaiting(surface) { await fixture.commits(1) }
        #expect(!presenter.isWaiting(surface), "the shorter size still waits for its frame after 2 s")
        #expect(surface.frame == CGRect(x: rest.minX, y: rest.minY, width: rest.width, height: rest.height - 30),
                "the landed frame is \(surface.frame)")

        // A hold taller than the area: the surface keeps the area's frame and asks for no other size.
        let area = surface.frame
        let taller = CGSize(width: rest.width, height: rest.height + 40)
        host.holdSurface(size: taller, anchor: .bottom)
        fixture.layoutNow()
        #expect(!presenter.isWaiting(surface), "a hold taller than its area asked for a frame at \(surface.frameOwnership.inFlight.map { "\($0)" } ?? "?")")
        let held = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < held, presenter.isWaiting(surface) { await fixture.commits(1) }
        #expect(surface.frame == area, "a hold taller than its area: the surface is \(surface.frame), its area \(area)")
        host.releaseSurfaceHold()
        host.followPaneMotion(nil, heldSize: nil)
        fixture.container.terminalHeight += 30
        fixture.layoutNow()
        #expect(fixture.mismatches.isEmpty,
                "\(fixture.mismatches.count) turns ended with the layer at one size and its frame at another: \(fixture.mismatches.prefix(8))")
    }

    /// A terminal hidden while its new size waits for its frame (a tab switched away mid-drag) takes the size its
    /// host gives it then, and keeps it: the pass that sees it hidden never puts back the older size it had asked
    /// for (review of 114c5ef217d).
    @Test func aTerminalHiddenWhileASizeWaitsKeepsItsNewestSize() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        // A size goes to Ghostty and waits for this turn's commit; the terminal hides in the same turn and its host
        // lays it out at another size.
        fixture.container.terminalWidth = 520
        fixture.layoutNow()
        let surface = fixture.session.surfaceView
        try #require(TerminalFramePresenter.forWindow(fixture.window).isWaiting(surface), "520 pt did not wait for its frame")
        fixture.session.view.isHidden = true
        fixture.container.terminalWidth = 460
        fixture.layoutNow()
        await fixture.commits(3)
        #expect(surface.frame.width == 460, "the hidden terminal is \(surface.frame.width) pt wide, its host gave it 460")
        fixture.session.view.isHidden = false
        await fixture.commits(3)
        #expect(surface.frame.width == 460, "shown again, the terminal is \(surface.frame.width) pt wide, its host gave it 460")
    }

    /// One resize: the first turn whose layer has the new bounds shows the frame drawn at that size, and Ghostty
    /// presented it in that commit (`host_fresh_presents`), not the renderer on its own afterwards.
    @Test func aReadyFrameIsPresentedInTheCommitThatChangesItsBounds() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let before = fixture.session.diagnostics.renderCounters
        await fixture.resize(to: 520)
        let landed = await fixture.waitShown(width: 520)
        #expect(landed, "520 pt never showed its own frame")
        let first = try #require(fixture.firstTurnAt(width: 520), "no turn had the layer at 520 pt")
        #expect(first.frame == first.layer, "the first turn with the new bounds showed a frame of \(first.frame), the layer is \(first.layer)")
        let after = fixture.session.diagnostics.renderCounters
        #expect((after?.hostFreshPresents ?? 0) > (before?.hostFreshPresents ?? 0),
                "the new size's frame was not presented in a commit (host_fresh_presents \(before?.hostFreshPresents ?? 0) -> \(after?.hostFreshPresents ?? 0))")
    }

    /// Reduce Motion, one Ctrl-Shift-H/L press at a time (films px-keys-single-3k-s1r-reduce: 6 refreshes missed per 4
    /// presses; the key's turn lands the layout at once). The key's turn never holds the main thread for the terminals:
    /// - the key turn, timed with `ContinuousClock` from `PaneResize.press` to the end of that turn's Core Animation
    ///   commit (stamped inside ``CommitBoundary``; a boundary that missed the commit is not a sample), is at most one
    ///   120 Hz refresh (8.33 ms) at the median of 6 presses (one slow press on a shared host is not the code's);
    /// - each press resized both terminals and both frames came through the presenter (`stats.presented` grows by 2,
    ///   no fallback);
    /// - Ghostty runs no display pass and draws no frame on main for the new sizes (render counters
    ///   `host_display_passes`, `host_main_draws`: a display pass of a new size waits up to 4 ms for the renderer's
    ///   frame);
    /// - every turn keeps ready-or-keep (no commit with the layer at one size and its frame at another).
    @Test func aReduceMotionKeyResizeNeverHoldsTheMainThreadForTheTerminals() async throws {
        let screen = try await KeyScreen()
        defer { screen.close() }
        // Warm-up press: one-time setup is not the key turn's cost.
        _ = await screen.press(.left)
        let before = screen.counters
        var turns: [Double] = []
        for direction in [LayoutDirection.right, .left, .right, .left, .right, .left] {
            let presentedBefore = screen.presented
            let pressed = await screen.press(direction)
            #expect(pressed.moved, "the press moved nothing")
            // Both terminals change size on each press: both new frames come through the presenter.
            #expect(screen.presented >= presentedBefore + 2, "a press's frames did not both come through the presenter (\(presentedBefore) -> \(screen.presented))")
            if let ms = pressed.turnMs { turns.append(ms) }
        }
        print("S4 m26 Reduce Motion presses: presenter \(TerminalFramePresenter.forWindow(screen.window).stats)")
        try #require(turns.count >= 4, "too few key turns were timed (\(turns.count) of 6: the boundary missed the rest)")
        let median = turns.sorted()[turns.count / 2]
        let after = screen.counters
        #expect(after.displayPasses == before.displayPasses,
                "Ghostty ran \(after.displayPasses - before.displayPasses) display passes on main for the key's new sizes")
        #expect(after.mainDraws == before.mainDraws, "Ghostty drew \(after.mainDraws - before.mainDraws) frames on main")
        #expect(median <= 1000.0 / 120, "the key turn's median is longer than one 120 Hz refresh (ms per press): \(turns)")
        #expect(screen.mismatches.isEmpty, "turns with the layer and its frame at different sizes: \(screen.mismatches.prefix(6))")
    }

    /// Two terminals side by side in a real layout (p1 | p2, Reduce Motion), in a window on screen; the presses are
    /// the app's (`PaneResize.press`).
    final class KeyScreen {
        final class Panes: LayoutPaneContentProvider {
            var containers: [PaneID: NSView] = [:]
            func makeContentView(for pane: PaneID) -> NSView {
                let container = NSView()
                containers[pane] = container
                return container
            }
        }

        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var sessions: [TerminalSession] = []
        var ios: [ScriptedTerminalIO] = []
        private let drew: Bool
        private var sampler: MainRunLoopObserver?
        private(set) var mismatches: [String] = []

        init() async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded() // sync-layout: the panes exist before their terminals attach
            let line = String(repeating: "y", count: 40)
            let text = Array(repeating: line, count: 400).joined(separator: "\r\n")
            for pane: PaneID in ["p1", "p2"] {
                let io = ScriptedTerminalIO()
                let session = TerminalSession(io: io)
                ios.append(io)
                guard session.surfaceView.surface != nil, let container = provider.containers[pane] else {
                    close()
                    try #require(Bool(false), "libghostty created no surface, or pane \(pane) has no container")
                    return
                }
                session.view.frame = container.bounds
                session.view.autoresizingMask = [.width, .height]
                container.addSubview(session.view)
                session.view.layoutSubtreeIfNeeded() // sync-layout: the attach's own layout pass
                io.send(.output(Data(text.utf8)))
                sessions.append(session)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, sessions.contains(where: { $0.surfaceView.presentedFrame == nil }) {
                await Self.commit()
            }
            let drawn = !sessions.contains { $0.surfaceView.presentedFrame == nil }
            let counted = sessions.allSatisfy { $0.diagnostics.renderCounters != nil }
            if !drawn || !counted { close() }
            try #require(drawn, "a terminal never showed its first frame")
            try #require(counted, "a terminal has no render counters")
            // Every turn ends after Core Animation's commit with what it committed.
            sampler = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                          drawsNothingAfterCommit: true) { [weak self] _ in self?.sample() }
        }

        func close() {
            sampler = nil
            for io in ios { io.finish() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        }

        private func sample() {
            for session in sessions {
                guard let layer = session.surfaceView.layer, let frame = session.surfaceView.presentedFrame else { continue }
                let scale = layer.contentsScale
                let width = Int((layer.bounds.width * scale).rounded()), height = Int((layer.bounds.height * scale).rounded())
                if width != frame.width || height != frame.height {
                    mismatches.append("layer \(width)x\(height) frame \(frame.width)x\(frame.height)")
                }
            }
        }

        /// Ghostty's main-thread display passes and draws, summed over the terminals (``init()`` requires counters).
        var counters: (displayPasses: UInt64, mainDraws: UInt64) {
            sessions.reduce((0, 0)) { sum, session in
                let counters = session.diagnostics.renderCounters
                return (sum.0 + (counters?.hostDisplayPasses ?? 0), sum.1 + (counters?.hostMainDraws ?? 0))
            }
        }

        /// Frames the window's presenter showed with their bounds, and passes that kept a frame long (data, m26).
        var presented: Int { TerminalFramePresenter.forWindow(window).stats.presented }
        var longKeeps: Int { TerminalFramePresenter.forWindow(window).stats.longKeeps }

        /// One press: whether p2 moved, and the key turn's main-thread time, from the press to the end of that turn's
        /// Core Animation commit (nil when the boundary missed it). Then commits until neither terminal waits for its
        /// frame (at most 2 s), so each press's presents count for that press.
        func press(_ direction: LayoutDirection) async -> (moved: Bool, turnMs: Double?) {
            let frame = root.context.hosts["p2"]?.frame
            let pressed = ContinuousClock.now
            let moved = PaneResize.press("p2", direction, model: model, view: root)
            let committed = await withCheckedContinuation { (done: CheckedContinuation<ContinuousClock.Instant?, Never>) in
                CommitBoundary().after { outcome in done.resume(returning: outcome == .committed ? .now : nil) }
            }
            // The real signal: the presenter's waiting state of both terminals, read after each commit.
            let presenter = TerminalFramePresenter.forWindow(window)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline, sessions.contains(where: { presenter.isWaiting($0.surfaceView) }) {
                await Self.commit()
            }
            for (index, session) in sessions.enumerated() where presenter.isWaiting(session.surfaceView) {
                let size = session.surfaceView.frameOwnership.inFlight.map { "\($0.width)x\($0.height) pt" } ?? "unknown"
                Issue.record("after \(direction) the terminal of p\(index + 1) still waits for its frame at \(size) after 2 s")
            }
            let ms = committed.map { end -> Double in
                let turn = pressed.duration(to: end)
                return Double(turn.components.seconds) * 1000 + Double(turn.components.attoseconds) / 1e15
            }
            return (moved && root.context.hosts["p2"]?.frame != frame, ms)
        }

        /// Returns after the next Core Animation commit of the main run loop.
        static func commit() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                CommitBoundary().after { _ in done.resume() }
            }
        }
    }

    /// Pixel sizes, for messages.
    struct Pixels: Equatable, CustomStringConvertible {
        var width: Int
        var height: Int
        var description: String { "\(width)x\(height)" }
    }

    /// One sampled turn: the layer's bounds and the shown frame, in pixels.
    struct Turn {
        var layer: Pixels
        var frame: Pixels
    }

    /// The window's content: its `layout()` gives the terminal the width asked for, as a pane's layout does.
    final class ResizingContainer: NSView {
        var terminalWidth: CGFloat = 600
        var terminalHeight: CGFloat = 300
        weak var terminal: NSView?

        override func layout() {
            super.layout()
            terminal?.frame = NSRect(x: 0, y: 0, width: terminalWidth, height: terminalHeight)
        }
    }

    final class Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let container: ResizingContainer
        private let drew: Bool
        private var observer: MainRunLoopObserver?
        private(set) var turns: [Turn] = []
        private(set) var samples = 0

        init() async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            // The runner's window may report itself occluded (an app never in front): draw anyway, as automation
            // launches do. Set back by ``close()``, which also runs when the setup below fails.
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            session = TerminalSession(io: io)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            container = ResizingContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = container
            container.terminal = session.view
            container.addSubview(session.view)
            window.orderFrontRegardless()
            do {
                try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            } catch {
                close()
                throw error
            }
            container.layoutSubtreeIfNeeded() // sync-layout: the first size, before the text
            let line = String(repeating: "x", count: 30)
            io.send(.output(Data(("\u{1b}[?25l" + Array(repeating: line, count: 6).joined(separator: "\r\n")).utf8)))
            let shown = await waitShown(width: 600)
            if !shown { close() }
            try #require(shown, "the terminal never showed its first frame")
            // Sample from here on: every turn ends after Core Animation's commit with what it committed.
            observer = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                           drawsNothingAfterCommit: true) { [weak self] _ in self?.sample() }
        }

        func close() {
            observer = nil
            io.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        }

        /// The surface layer's bounds, in pixels.
        var layerPixels: Pixels? {
            guard let layer = session.surfaceView.layer else { return nil }
            let scale = layer.contentsScale
            return Pixels(width: Int((layer.bounds.width * scale).rounded()), height: Int((layer.bounds.height * scale).rounded()))
        }

        /// The size of the frame the surface shows, in pixels; nil before its first frame.
        var shownPixels: Pixels? {
            session.surfaceView.presentedFrame.map { Pixels(width: $0.width, height: $0.height) }
        }

        private func sample() {
            guard let layer = layerPixels, let frame = shownPixels else { return }
            samples += 1
            turns.append(Turn(layer: layer, frame: frame))
        }

        /// The turns that ended with the layer and its frame at different sizes.
        var mismatches: [String] {
            turns.filter { $0.layer != $0.frame }.map { "layer \($0.layer) frame \($0.frame)" }
        }

        /// The first sampled turn whose layer is `width` points wide.
        func firstTurnAt(width: CGFloat) -> Turn? {
            let scale = session.surfaceView.layer?.contentsScale ?? 2
            return turns.first { $0.layer.width == Int((width * scale).rounded()) }
        }

        /// Lays the container and the terminal's host out now, in this turn (the host's own layout places the surface).
        func layoutNow() {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded() // sync-layout: the test's own turn is the one under test
            session.view.needsLayout = true
            session.view.layoutSubtreeIfNeeded() // sync-layout: a hidden host is laid out too
        }

        /// Resizes the terminal to `width` through the next display cycle's layout and returns after that commit.
        func resize(to width: CGFloat) async {
            container.terminalWidth = width
            container.needsLayout = true
            await commits(1)
        }

        /// Returns after `count` main run-loop turns ended with a Core Animation commit.
        func commits(_ count: Int) async {
            for _ in 0..<count {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CommitBoundary().after { _ in done.resume() }
                }
            }
        }

        /// Waits, commit by commit (at most 10 s), until the shown frame is `width` points wide at `scale` (default:
        /// the layer's scale).
        func waitShown(width: CGFloat, scale: CGFloat? = nil) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                let scale = scale ?? session.surfaceView.layer?.contentsScale ?? 2
                if shownPixels?.width == Int((width * scale).rounded()) { return true }
                await commits(1)
            }
            return false
        }

        /// Ghostty's frames of this surface that went to the screen off the main thread.
        var offMainPresents: UInt64 {
            guard let surface = session.surfaceView.surface else { return 0 }
            return ghostty_surface_render_counters(surface).host_off_main_presents
        }
    }
}
