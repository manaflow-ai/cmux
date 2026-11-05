import AppKit
import CmuxNextBridge
// Only the grid size: CmuxNextDaemon has its own PaneID and SplitID (the daemon's handles).
import CmuxNextTestSupport
import struct CmuxNextDaemon.CellSize
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import Testing

/// One Cmd-D resizes each terminal's PTY once (review of pl-motion-core b14). A split's new pane gets its
/// terminal from the daemon's echo while the pane still springs (~75 ms in): the new terminal's first grid
/// report (`TerminalSession.init`, forced, from a view that is not in the pane yet) must not reach the PTY
/// before the spring lands, or the PTY resizes and reflows twice (the prompt redrawn at a size no frame rests
/// at, then again at the final one). No layout hold holds the grids: each terminal sends its final grid itself
/// when the spring starts, or when it joins a pane on a spring. Real terminal sessions; the PTY owner side is
/// the app's (`DaemonTerminalIO.resize`: each reported grid goes to the `ResizeCoordinator` on the main
/// actor). Frames step at a fixed 120 Hz dt.
@MainActor
@Suite(.closesItsWindows)
struct SplitTerminalResizeCountTests {
    /// The PTY a resize reaches (`DaemonTerminalIO.applySettled`), counting them.
    final class PTY: ResizeTarget {
        static let marker = Data("\u{1}flush\u{1}".utf8)
        var applied: [CellSize] = []
        var awaitsEcho: Bool { false }
        func applySettled(_ size: CellSize) { applied.append(size) }

        private var flushed: CheckedContinuation<Void, Never>?

        func received(_ data: Data) {
            guard data == Self.marker else { return }
            flushed?.resume()
            flushed = nil
        }

        /// Returns once every grid `session` reported so far reached the coordinator: the input queue is
        /// ordered (`TerminalSession` writer), so the marker written after them arrives after them.
        func flush(_ session: TerminalSession) async {
            await withCheckedContinuation { continuation in
                flushed = continuation
                session.sendBytes(Self.marker)
            }
        }
    }

    /// The app's daemon IO, as far as grids go: each reported grid is submitted on the main actor.
    nonisolated final class CoordinatedIO: TerminalIO {
        let events: AsyncStream<TerminalIOEvent>
        private let eventsEnd: AsyncStream<TerminalIOEvent>.Continuation
        let pty: PTY
        let coordinator: ResizeCoordinator

        init(pty: PTY, coordinator: ResizeCoordinator) {
            (events, eventsEnd) = AsyncStream<TerminalIOEvent>.makeStream()
            self.pty = pty
            self.coordinator = coordinator
        }

        func finish() { eventsEnd.finish() }

        func write(_ data: Data) async {
            await MainActor.run { pty.received(data) }
        }

        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
            guard cols > 0, rows > 0 else { return }
            await MainActor.run { coordinator.submit(pty, size: CellSize(cols: cols, rows: rows)) }
        }
    }

    /// One terminal in a pane.
    struct Terminal {
        let session: TerminalSession
        let io: CoordinatedIO
        var pty: PTY { io.pty }
    }

    /// Each pane's content: a container its terminal is installed into when its tab arrives.
    final class Panes: LayoutPaneContentProvider {
        var containers: [PaneID: NSView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let container = NSView()
            containers[pane] = container
            return container
        }
    }

    static let dt = 1.0 / 120
    static let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// `pair` after Cmd-D on p2, as the store's provisional split shows it.
    static let pairSplit: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// Opens the coordinator only for the test's own frames (`ResizeCoordinator.init(holds:)`): its app frame
    /// client may also tick from the display link while the test awaits, and the test is the clock.
    final class TickGate {
        var open = false
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let gate: TickGate
        let coordinator: ResizeCoordinator
        var terminals: [PaneID: Terminal] = [:]

        init(_ tree: SplitNode) {
            let gate = TickGate()
            self.gate = gate
            coordinator = ResizeCoordinator(holds: { _ in !gate.open })
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        /// A terminal session for `pane` (the daemon's echo of its tab), installed in its container.
        func attachTerminal(_ pane: PaneID) throws {
            let io = CoordinatedIO(pty: PTY(), coordinator: coordinator)
            let session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            let container = try #require(provider.containers[pane])
            session.view.frame = container.bounds
            session.view.autoresizingMask = [.width, .height]
            container.addSubview(session.view)
            // The attach's own layout pass: the surface takes the pane's size now.
            session.view.needsLayout = true
            session.view.layoutSubtreeIfNeeded()
            terminals[pane] = Terminal(session: session, io: io)
        }

        /// Every grid reported so far reaches the coordinator, then the coordinator runs one frame.
        func deliver() async {
            for terminal in terminals.values { await terminal.pty.flush(terminal.session) }
            gate.open = true
            _ = coordinator.tick()
            gate.open = false
        }

        /// Delivers until the coordinator has nothing left to send (at most 10 frames).
        func drain() async {
            for _ in 1...10 {
                await deliver()
                if coordinator.isIdle { return }
            }
        }

        /// One display frame: the layout steps, the reports of that frame reach the coordinator, it ticks.
        @discardableResult
        func step() async -> Bool {
            let moving = root.advanceFrame(SplitTerminalResizeCountTests.dt)
            await deliver()
            return moving
        }

        func close() {
            for terminal in terminals.values {
                terminal.session.close()
                terminal.io.finish()
            }
            window.close()
        }
    }

    /// Cmd-D on p2 of p1 | p2; p3's terminal arrives 9 frames (75 ms) into the spring, as the daemon's echo
    /// does. Every terminal's PTY resizes at most once, at its final grid, and the new pane's exactly once.
    @Test func aSplitResizesEachPTYOnceIncludingTheNewPanesTerminalAttachedMidSpring() async throws {
        _ = NSApplication.shared
        let screen = Screen(Self.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        for terminal in screen.terminals.values { terminal.pty.applied.removeAll() }

        // The key's turn: the sizing, then the split.
        let changes = screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal)
        _ = screen.model.showSplitSizing(changes)
        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.pairSplit))])
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...9 { moving = await screen.step() }
        #expect(moving, "the split landed before its new pane's terminal arrived")
        try screen.attachTerminal("p3")
        await screen.deliver()
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the split never landed")
        await screen.drain()

        for pane: PaneID in ["p1", "p2", "p3"] {
            let terminal = try #require(screen.terminals[pane])
            let applied = terminal.pty.applied
            #expect(applied.count <= 1, "\(pane): \(applied.count) PTY resizes for one Cmd-D: \(applied)")
            if let grid = terminal.session.surfaceView.fittedGrid, let last = applied.last {
                #expect(last == CellSize(cols: grid.columns, rows: grid.rows), "\(pane): the PTY rests at \(last), the view fits \(grid)")
            }
        }
        let added = try #require(screen.terminals["p3"]).pty.applied
        #expect(added.count == 1, "the new pane's terminal resized its PTY \(added.count) times: \(added)")
    }
}
