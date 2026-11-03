import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
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
