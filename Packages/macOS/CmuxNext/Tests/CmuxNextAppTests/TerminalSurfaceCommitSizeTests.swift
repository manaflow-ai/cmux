import AppKit
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
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
    ///   commit (stamped inside ``CommitBoundary``), is at most one 120 Hz refresh (8.33 ms) at the median of 4 presses
    ///   and at most two (16.7 ms) for any press;
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
        for direction in [LayoutDirection.right, .left, .right, .left] {
            let pressed = await screen.press(direction)
            #expect(pressed.moved, "the press moved nothing")
            turns.append(pressed.turnMs)
        }
        let median = turns.sorted()[turns.count / 2]
        let after = screen.counters
        #expect(after.displayPasses == before.displayPasses,
                "Ghostty ran \(after.displayPasses - before.displayPasses) display passes on main for the key's new sizes")
        #expect(after.mainDraws == before.mainDraws, "Ghostty drew \(after.mainDraws - before.mainDraws) frames on main")
        #expect(median <= 1000.0 / 120, "the key turn's median is longer than one 120 Hz refresh (ms per press): \(turns)")
        #expect(turns.allSatisfy { $0 <= 2000.0 / 120 }, "a key turn held the main thread for two refreshes or more: \(turns)")
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
            let on = TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(false))
            try #require(on == .bool(false), "the switch motion.frameOwner.terminals is not registered")
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
                try #require(session.surfaceView.surface != nil, "libghostty created no surface")
                let container = try #require(provider.containers[pane])
                session.view.frame = container.bounds
                session.view.autoresizingMask = [.width, .height]
                container.addSubview(session.view)
                session.view.layoutSubtreeIfNeeded() // sync-layout: the attach's own layout pass
                io.send(.output(Data(text.utf8)))
                sessions.append(session)
                ios.append(io)
            }
            for _ in 0..<240 where sessions.contains(where: { $0.surfaceView.presentedFrame == nil }) {
                await Self.commit()
            }
            try #require(!sessions.contains { $0.surfaceView.presentedFrame == nil }, "a terminal never showed its first frame")
            // Every turn ends after Core Animation's commit with what it committed.
            sampler = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                          drawsNothingAfterCommit: true) { [weak self] _ in self?.sample() }
        }

        func close() {
            sampler = nil
            for io in ios { io.finish() }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, nil)
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

        /// Ghostty's main-thread display passes and draws, summed over the terminals.
        var counters: (displayPasses: UInt64, mainDraws: UInt64) {
            sessions.reduce((0, 0)) { sum, session in
                let counters = session.diagnostics.renderCounters
                return (sum.0 + (counters?.hostDisplayPasses ?? 0), sum.1 + (counters?.hostMainDraws ?? 0))
            }
        }

        /// One press: whether p2 moved, and the key turn's main-thread time, from the press to the end of that turn's
        /// Core Animation commit. Then 6 more commits, for the frames to land.
        func press(_ direction: LayoutDirection) async -> (moved: Bool, turnMs: Double) {
            let frame = root.context.hosts["p2"]?.frame
            let pressed = ContinuousClock.now
            let moved = PaneResize.press("p2", direction, model: model, view: root)
            let committed = await withCheckedContinuation { (done: CheckedContinuation<ContinuousClock.Instant, Never>) in
                CommitBoundary().after { _ in done.resume(returning: .now) }
            }
            let turn = pressed.duration(to: committed)
            for _ in 0..<6 { await Self.commit() }
            let ms = Double(turn.components.seconds) * 1000 + Double(turn.components.attoseconds) / 1e15
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
        weak var terminal: NSView?

        override func layout() {
            super.layout()
            terminal?.frame = NSRect(x: 0, y: 0, width: terminalWidth, height: 300)
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
            let on = TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(true))
            try #require(on == .bool(true), "the switch motion.frameOwner.terminals is not registered")
            // The runner's window may report itself occluded (an app never in front): draw anyway, as automation
            // launches do.
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
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            container.layoutSubtreeIfNeeded() // sync-layout: the first size, before the text
            let line = String(repeating: "x", count: 30)
            io.send(.output(Data(("\u{1b}[?25l" + Array(repeating: line, count: 6).joined(separator: "\r\n")).utf8)))
            let shown = await waitShown(width: 600)
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
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, nil)
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

        /// Waits, commit by commit (at most 240), until the shown frame is `width` points wide at the layer's scale.
        func waitShown(width: CGFloat) async -> Bool {
            for _ in 0..<240 {
                let scale = session.surfaceView.layer?.contentsScale ?? 2
                if shownPixels?.width == Int((width * scale).rounded()) { return true }
                await commits(1)
            }
            return false
        }
    }
}
