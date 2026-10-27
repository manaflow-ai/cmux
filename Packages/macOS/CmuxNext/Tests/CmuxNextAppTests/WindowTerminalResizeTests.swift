import AppKit
import CmuxNextBridge
// Only the grid size: CmuxNextDaemon has its own PaneID (the daemon's handles).
import struct CmuxNextDaemon.CellSize
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import QuartzCore
import Testing

/// Window and pane resizes with real terminals (Lawrence 2026-10-27: "we need resize tests, for both
/// windows, and panes too"; resizing the window made the terminal look broken). Each pane holds a
/// real ``TerminalSession`` on libghostty with a long scrollback and a prompt on its last line. Its
/// IO stands in for the app's daemon IO as far as grids go: every grid the view reports goes to the
/// `ResizeCoordinator`, the coordinator applies it to the PTY, and the PTY announces it back
/// (`.resize`, as the daemon does once the PTY has the size), which locks the grid the surface draws.
/// The PTY echoes in the same frame or some frames later, or loses an echo, as a daemon can; while
/// an echo is due the coordinator holds the newest grid (`awaitsEcho`, as `DaemonTerminalIO`).
///
/// After every settled step, every visible pane's terminal fits its pane: its surface has the pane's
/// size, the grid is what fits at the font's cell size, the PTY holds that grid with the pixel size
/// of that many cells, and the surface draws that grid. And what a person sees stays right: no
/// resize asked Ghostty to scroll (`scroll_to_row`), Ghostty's viewport is still at the bottom of
/// the scrollback, and the prompt is on screen.
@MainActor @Suite(.serialized)
struct WindowTerminalResizeTests {
    /// The PTY a resize reaches (`DaemonTerminalIO.applySettled`); it announces each size back.
    final class PTY: ResizeTarget {
        static let marker = Data("\u{1}flush\u{1}".utf8)
        var applied: [CellSize] = []
        /// The pixel sizes the view sent with its grids, in order.
        var pixels: [CGSize] = []
        /// Frames from a grid's apply to its echo; 0 echoes in `applySettled`, as one frame.
        var echoDelay = 0
        /// The next applied grid is never echoed (a lost or refused resize).
        var losesNextEcho = false
        /// Applied grids whose echo has not come (`TerminalAttachMachine.echoesDue`): an echo
        /// clears its grid and every older one.
        private(set) var due: [CellSize] = []
        private var scheduled: [(size: CellSize, frames: Int)] = []
        var awaitsEcho: Bool { !due.isEmpty }
        /// An echo is scheduled and has not come yet.
        var echoesPending: Bool { !scheduled.isEmpty }
        var announce: ((CellSize) -> Void)?
        /// The terminal's window, for its full screen hold (the app passes the view's window).
        weak var window: NSWindow?
        func applySettled(_ size: CellSize) {
            applied.append(size)
            due = Array((due + [size]).suffix(8))
            if losesNextEcho {
                losesNextEcho = false
                return
            }
            if echoDelay == 0 { echo(size) } else { scheduled.append((size, echoDelay)) }
        }

        /// One frame: the echoes whose delay ran out come, in the order the PTY applied their grids.
        func frame() {
            for index in scheduled.indices { scheduled[index].frames -= 1 }
            while let first = scheduled.first, first.frames <= 0 {
                scheduled.removeFirst()
                echo(first.size)
            }
        }

        private func echo(_ size: CellSize) {
            if let mine = due.firstIndex(of: size) { due.removeFirst(mine + 1) }
            announce?(size)
        }

        private var flushed: CheckedContinuation<Void, Never>?

        func received(_ data: Data) {
            guard data == Self.marker else { return }
            flushed?.resume()
            flushed = nil
        }

        /// Returns once every grid `session` reported so far reached the coordinator (the input queue is
        /// ordered, so the marker written after them arrives after them).
        func flush(_ session: TerminalSession) async {
            await withCheckedContinuation { continuation in
                flushed = continuation
                session.sendBytes(Self.marker)
            }
        }
    }

    nonisolated final class CoordinatedIO: TerminalIO {
        let events: AsyncStream<TerminalIOEvent>
        private let eventsEnd: AsyncStream<TerminalIOEvent>.Continuation
        let pty: PTY
        let coordinator: ResizeCoordinator

        @MainActor init(pty: PTY, coordinator: ResizeCoordinator) {
            let (events, end) = AsyncStream<TerminalIOEvent>.makeStream()
            self.events = events
            eventsEnd = end
            self.pty = pty
            self.coordinator = coordinator
            pty.announce = { size in end.yield(.resize(cols: size.cols, rows: size.rows)) }
        }

        func finish() { eventsEnd.finish() }

        /// The program's output, as the daemon streams it.
        func output(_ text: String) { eventsEnd.yield(.output(Data(text.utf8))) }

        func write(_ data: Data) async {
            await MainActor.run { pty.received(data) }
        }

        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
            guard cols > 0, rows > 0 else { return }
            await MainActor.run {
                pty.pixels.append(CGSize(width: pixelWidth, height: pixelHeight))
                coordinator.submit(pty, size: CellSize(cols: cols, rows: rows), window: pty.window)
            }
        }
    }

    /// The rows the terminal's scroller asked Ghostty to scroll to (`scroll_to_row`).
    final class ScrollRequests {
        var rows: [UInt64] = []
    }

    struct Terminal {
        let session: TerminalSession
        let io: CoordinatedIO
        let scrolls: ScrollRequests
        var pty: PTY { io.pty }
    }

    final class Panes: LayoutPaneContentProvider {
        var containers: [PaneID: NSView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let container = NSView()
            containers[pane] = container
            return container
        }
    }

    /// The coordinator runs only on the test's frames.
    final class Frames {
        var open = false
    }

    static let dt = 1.0 / 120
    /// The last line of every terminal's output: the prompt, with the cursor after it.
    static let prompt = "PROMPT$ "
    /// p1 | (p2 / p3).
    static let nested: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                          b: .split("d", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
    static let panes: [PaneID] = ["p1", "p2", "p3"]

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let frames: Frames
        let coordinator: ResizeCoordinator
        var terminals: [PaneID: Terminal] = [:]
        /// The font's cell in pixels, from the first terminal: no resize changes it.
        var cell: CGSize?
        /// Mouse event times (the drag's release velocity reads them).
        var eventTime = CACurrentMediaTime() - 100

        /// `WindowDrawPolicy.drawsWhenOccluded` before the rig.
        private let drewWhenOccluded = WindowDrawPolicy.drawsWhenOccluded

        init(screens: [LayoutScreen], active: ScreenID, size: NSSize = NSSize(width: 1200, height: 800)) {
            // A TerminalSession gets a libghostty surface only on a started runtime (GhosttyTestRuntime.swift).
            GhosttyRuntime.startedForTests()
            // The runner's window may report itself occluded (an app never in front): draw anyway, as
            // automation launches do. An occluded surface's renderer is paused, and Ghostty reports its
            // scrollbar only from the renderer.
            WindowDrawPolicy.drawsWhenOccluded = true
            let frames = Frames()
            self.frames = frames
            // The app's hold (`Motion.isFullScreenTransitioning`, the coordinator's default), and the
            // coordinator's own display frames gated to the test's frames.
            coordinator = ResizeCoordinator(holds: { window in
                !frames.open || Motion.isFullScreenTransitioning(window)
            })
            model = LayoutModel(screens: screens, activeScreenID: active, focusedPane: nil)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            // Each drag event moves the layout at once (no window coalescer in a test).
            root.dragFrameInput = nil
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            window.orderFrontRegardless()
        }

        func attachTerminal(_ pane: PaneID) throws {
            let io = CoordinatedIO(pty: PTY(), coordinator: coordinator)
            io.pty.window = window
            let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            let container = try #require(provider.containers[pane], "pane \(pane) has no content view")
            session.view.frame = container.bounds
            session.view.autoresizingMask = [.width, .height]
            container.addSubview(session.view)
            session.view.needsLayout = true
            session.view.layoutSubtreeIfNeeded()
            let scrolls = ScrollRequests()
            let scroller = session.view.scroller
            let forward = scroller.onScrollToRow
            scroller.onScrollToRow = { row in
                scrolls.rows.append(row)
                forward?(row)
            }
            terminals[pane] = Terminal(session: session, io: io, scrolls: scrolls)
        }

        func attachTerminals(_ panes: [PaneID]) throws {
            for pane in panes { try attachTerminal(pane) }
        }

        /// Writes 300 numbered lines and the prompt to every terminal of `panes` and waits until each
        /// shows the prompt over a scrollback (Ghostty's scrollbar has more rows than the screen).
        func fillScrollback(_ panes: [PaneID]) async throws {
            var text = ""
            for line in 0..<300 { text += "line \(line)\r\n" }
            text += WindowTerminalResizeTests.prompt
            for pane in panes { try #require(terminals[pane]).io.output(text) }
            let deadline = Date().addingTimeInterval(5)
            for pane in panes {
                let terminal = try #require(terminals[pane])
                while Date() < deadline {
                    draw()
                    let bar = terminal.session.model.scrollbar
                    if let bar, bar.totalRows > bar.visibleRows,
                       terminal.session.surfaceView.viewportText()?.contains(WindowTerminalResizeTests.prompt) == true { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let bar = try #require(terminal.session.model.scrollbar, "\(pane): Ghostty reported no scrollbar")
                try #require(bar.totalRows > bar.visibleRows,
                             "\(pane) has no scrollback: \(bar); its screen ends \(String((terminal.session.surfaceView.viewportText() ?? "").suffix(120)).debugDescription)")
            }
            await deliver()
            for pane in panes { terminals[pane]?.scrolls.rows.removeAll() }
        }

        /// Every grid reported so far reaches the coordinator, due echoes come, it runs one frame, and
        /// each terminal's scroller shows Ghostty's newest scrollbar (the app's per-frame apply).
        func deliver() async {
            for terminal in terminals.values { await terminal.pty.flush(terminal.session) }
            for terminal in terminals.values { terminal.pty.frame() }
            frames.open = true
            _ = coordinator.tick()
            frames.open = false
            draw()
            for terminal in terminals.values { terminal.session.view.scrollbarWatch?.flushIfDirty() }
        }

        /// Draws every terminal once, as the display link does each frame in the app (an off-screen
        /// test window has none). Ghostty reports its scrollbar only from a draw (renderer `drawFrame`).
        func draw() {
            for terminal in terminals.values {
                if let surface = terminal.session.surfaceView.surface { ghostty_surface_draw(surface) }
            }
        }

        /// Frames until the layout rests, the coordinator has nothing left to send and no echo is due.
        func settle() async {
            for _ in 1...240 {
                let moving = root.advanceFrame(WindowTerminalResizeTests.dt)
                await deliver()
                if !moving && coordinator.isIdle && terminals.values.allSatisfy({ !$0.pty.echoesPending }) { break }
            }
            await deliver()
        }

        /// The window's content takes `size`: one layout pass, as one live-resize frame.
        func resizeWindow(_ size: NSSize) {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
        }

        func clearApplied() {
            for terminal in terminals.values {
                terminal.pty.applied.removeAll()
                terminal.pty.pixels.removeAll()
            }
        }

        func fitted(_ pane: PaneID) -> CellSize? {
            terminals[pane]?.session.surfaceView.fittedGrid.map { CellSize(cols: $0.columns, rows: $0.rows) }
        }

        /// Waits (up to 5 s) until every terminal of `panes` draws the grid its PTY announced last.
        func waitForAnnouncedGrids(_ panes: [PaneID]) async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let drawn = panes.allSatisfy { pane in
                    guard let terminal = terminals[pane], let last = terminal.pty.applied.last else { return true }
                    return terminal.session.surfaceView.currentGrid == TerminalGridSize(columns: last.cols, rows: last.rows)
                }
                if drawn { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// Settles, then every terminal of `panes` fits its pane and shows the bottom of its scrollback.
        func expectSettled(_ panes: [PaneID], _ step: String) async throws {
            await settle()
            await waitForAnnouncedGrids(panes)
            for pane in panes { try expectFits(pane, step) }
            for pane in panes { try await expectAtBottom(pane, step) }
        }

        /// The pane's terminal fits its pane, at the font's cell size, in its surface, its PTY and its frames.
        func expectFits(_ pane: PaneID, _ step: String) throws {
            let terminal = try #require(terminals[pane])
            let view = terminal.session.surfaceView
            let surface = try #require(view.surface)
            let container = try #require(provider.containers[pane])
            #expect(terminal.session.view.frame.size == container.bounds.size,
                    "\(step): \(pane)'s terminal is \(terminal.session.view.frame.size), its pane \(container.bounds.size)")
            let pixels = view.convertToBacking(view.bounds.size)
            let size = ghostty_surface_size(surface)
            let cellW = Int(size.cell_width_px), cellH = Int(size.cell_height_px)
            if cell == nil { cell = CGSize(width: cellW, height: cellH) }
            #expect(CGSize(width: cellW, height: cellH) == cell, "\(step): \(pane)'s cell is \(cellW)x\(cellH) px, the font's \(cell!)")
            let fitted = try #require(view.fittedGrid, "\(step): \(pane) never sized its surface")
            #expect(fitted == TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows)),
                    "\(step): \(pane) reported \(fitted), its surface fits \(size.columns)x\(size.rows)")
            // What fits: whole cells inside the view, with at most the padding left over.
            #expect(fitted.columns * cellW <= Int(pixels.width) && (fitted.columns + 3) * cellW > Int(pixels.width),
                    "\(step): \(fitted.columns) columns of \(cellW) px in a \(pixels.width) px wide view")
            #expect(fitted.rows * cellH <= Int(pixels.height) && (fitted.rows + 3) * cellH > Int(pixels.height),
                    "\(step): \(fitted.rows) rows of \(cellH) px in a \(pixels.height) px high view")
            let applied = terminal.pty.applied.last
            #expect(applied == CellSize(cols: fitted.columns, rows: fitted.rows),
                    "\(step): \(pane)'s PTY rests at \(String(describing: applied)), its view fits \(fitted)")
            if let sent = terminal.pty.pixels.last {
                #expect(sent == CGSize(width: fitted.columns * cellW, height: fitted.rows * cellH),
                        "\(step): \(pane) sent \(sent) px for \(fitted) cells of \(cellW)x\(cellH)")
            }
            let grid = ghostty_surface_grid(surface)
            #expect(grid.locked, "\(step): \(pane)'s surface draws no announced grid")
            #expect(view.currentGrid == fitted,
                    "\(step): \(pane) draws \(String(describing: view.currentGrid)) after the resize settled, its view fits \(fitted)")
        }

        /// What a person sees after the resize: no resize asked Ghostty to scroll into the history
        /// (`scroll_to_row`, the dogfood bug: AppKit clamps a taller scroller clip and the scroller took
        /// it for a knob drag), Ghostty's viewport is at the bottom (the scrollbar the scroller follows:
        /// offset + visible rows == total), and the prompt with the cursor is on screen.
        func expectAtBottom(_ pane: PaneID, _ step: String) async throws {
            let terminal = try #require(terminals[pane])
            #expect(terminal.scrolls.rows.isEmpty,
                    "\(step): \(pane)'s resize asked Ghostty for rows \(terminal.scrolls.rows) (scroll_to_row): it scrolled into its history")
            let view = terminal.session.surfaceView
            let rows = UInt64(view.currentGrid?.rows ?? 0)
            var bar = terminal.session.model.scrollbar
            var text = view.viewportText() ?? ""
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                draw()
                bar = terminal.session.model.scrollbar
                text = view.viewportText() ?? ""
                if let bar, bar.visibleRows == rows, bar.offsetRows + bar.visibleRows == bar.totalRows,
                   text.contains(WindowTerminalResizeTests.prompt) { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let shown = try #require(bar, "\(step): \(pane) has no scrollbar")
            #expect(shown.totalRows > shown.visibleRows, "\(step): \(pane) lost its scrollback: \(shown)")
            #expect(shown.offsetRows + shown.visibleRows == shown.totalRows,
                    "\(step): \(pane)'s viewport is \(shown.totalRows - min(shown.totalRows, shown.offsetRows + shown.visibleRows)) rows above the bottom: \(shown)")
            #expect(text.contains(WindowTerminalResizeTests.prompt),
                    "\(step): \(pane)'s prompt is out of view; the screen ends \(String(text.suffix(160)).debugDescription)")
            terminal.scrolls.rows.removeAll()
        }

        func close() {
            for terminal in terminals.values {
                terminal.session.close()
                terminal.io.finish()
            }
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drewWhenOccluded
        }
    }

    static func screen(_ id: ScreenID, _ tree: SplitNode) -> LayoutScreen {
        LayoutScreen(id: id, name: id.rawValue, layout: .splits(tree))
    }

    /// A rig of p1 | (p2 / p3) whose terminals show a prompt under a long scrollback, settled.
    static func filledRig() async throws -> Rig {
        let rig = Rig(screens: [screen("s", nested)], active: "s")
        try rig.attachTerminals(panes)
        await rig.settle()
        await rig.waitForAnnouncedGrids(panes)
        try await rig.fillScrollback(panes)
        return rig
    }

    static let sizes: [NSSize] = [
        NSSize(width: 1600, height: 1000), NSSize(width: 900, height: 600), NSSize(width: 2400, height: 1400),
        NSSize(width: 480, height: 320), NSSize(width: 1201, height: 799), NSSize(width: 1200, height: 800),
    ]

    /// A window resize to each size (grow, shrink, very large, small, off by a point), settled: every
    /// pane's terminal of p1 | (p2 / p3) fits its new frame, its PTY holds that grid, it draws it,
    /// and each still shows its prompt at the bottom of its scrollback (each grow is the dogfood bug's
    /// step: the window grows while the terminal shows the bottom of a long scrollback).
    @Test func aWindowResizeResizesEveryPaneTerminalToItsFrame() async throws {
        _ = NSApplication.shared
        let rig = try await Self.filledRig()
        defer { rig.close() }
        for pane in Self.panes { try rig.expectFits(pane, "start") }
        for size in Self.sizes {
            rig.resizeWindow(size)
            try await rig.expectSettled(Self.panes, "window \(Int(size.width))x\(Int(size.height))")
        }
    }

    /// A live resize: the window edge moves every frame for 60 frames, out and back. With an echo in
    /// the same frame, each frame's grid is the PTY's by the end of that frame (real time: the PTY's
    /// grids are exactly the frames' grids, in order); with an echo `echoDelay` frames later, the
    /// coordinator keeps one grid in flight and sends the newest one, never a stale one. The drag ends
    /// at the last frame's size (`didEndLiveResize` brings no new size): every terminal fits that
    /// frame, draws its grid, no grid is sent after the drag for an echo-in-frame PTY, and every
    /// prompt is still at the bottom.
    @Test(arguments: [0, 3])
    func aLiveResizeEndsWithEveryTerminalOnItsLastFrame(echoDelay: Int) async throws {
        _ = NSApplication.shared
        Motion.liveResizeOverride = true
        defer { Motion.liveResizeOverride = nil }
        let rig = try await Self.filledRig()
        defer { rig.close() }
        for pane in Self.panes { rig.terminals[pane]?.pty.echoDelay = echoDelay }
        rig.clearApplied()
        var expected: [PaneID: [CellSize]] = [:]
        var last: [PaneID: CellSize] = [:]
        for pane in Self.panes { last[pane] = rig.fitted(pane) }
        for frame in 0..<60 {
            let out = frame < 30 ? frame : 60 - frame
            rig.resizeWindow(NSSize(width: 1200 + CGFloat(out) * 17, height: 800 + CGFloat(out) * 7))
            _ = rig.root.advanceFrame(Self.dt)
            let before = Dictionary(uniqueKeysWithValues: Self.panes.map { ($0, rig.terminals[$0]?.pty.applied.count ?? 0) })
            await rig.deliver()
            for pane in Self.panes {
                let terminal = try #require(rig.terminals[pane])
                let fitted = rig.fitted(pane)
                if let fitted, fitted != last[pane] { expected[pane, default: []].append(fitted) }
                last[pane] = fitted
                if echoDelay == 0 {
                    #expect(terminal.pty.applied.last == fitted,
                            "live frame \(frame): \(pane)'s PTY has \(String(describing: terminal.pty.applied.last)), its view fits \(String(describing: fitted))")
                } else {
                    #expect(terminal.pty.due.count <= 1, "live frame \(frame): \(pane) has \(terminal.pty.due.count) grids in flight")
                    if terminal.pty.applied.count > before[pane, default: 0] {
                        #expect(terminal.pty.applied.last == fitted,
                                "live frame \(frame): \(pane)'s PTY got \(String(describing: terminal.pty.applied.last)), not the newest grid \(String(describing: fitted))")
                    }
                }
            }
        }
        if echoDelay == 0 {
            for pane in Self.panes {
                let applied = try #require(rig.terminals[pane]).pty.applied
                #expect(applied == expected[pane, default: []], "\(pane)'s PTY took \(applied), the frames fit \(expected[pane, default: []])")
            }
        } else {
            for pane in Self.panes {
                let count = try #require(rig.terminals[pane]).pty.applied.count
                #expect(count >= 10, "\(pane)'s PTY took \(count) grids in a 60-frame drag: the drag is not real time")
            }
        }
        let sentDuringDrag = Dictionary(uniqueKeysWithValues: Self.panes.map { ($0, rig.terminals[$0]?.pty.applied.count ?? 0) })
        Motion.liveResizeOverride = false
        try await rig.expectSettled(Self.panes, "after the live resize (echo \(echoDelay) frames)")
        if echoDelay == 0 {
            for pane in Self.panes {
                let count = rig.terminals[pane]?.pty.applied.count ?? 0
                #expect(count == sentDuringDrag[pane], "\(pane)'s PTY took \(count - (sentDuringDrag[pane] ?? 0)) more grids after the drag ended")
            }
        }
    }

    /// A live resize whose PTY loses one echo (a refused or lost resize): the coordinator holds the
    /// newest grid for at most `ResizeCoordinator.echoWaitFrames`, then sends it, and the drag ends with
    /// every terminal on its last frame.
    @Test func aLostEchoHoldsALiveResizeOnlyUntilTheEchoWaitEnds() async throws {
        _ = NSApplication.shared
        Motion.liveResizeOverride = true
        defer { Motion.liveResizeOverride = nil }
        let rig = try await Self.filledRig()
        defer { rig.close() }
        for pane in Self.panes { rig.terminals[pane]?.pty.echoDelay = 2 }
        rig.clearApplied()
        var lostAt: [PaneID: Int] = [:]
        var resumedAt: [PaneID: Int] = [:]
        for frame in 0..<70 {
            if frame == 8 { for pane in Self.panes { rig.terminals[pane]?.pty.losesNextEcho = true } }
            let out = frame % 35
            rig.resizeWindow(NSSize(width: 1200 + CGFloat(out) * 13, height: 800 + CGFloat(out) * 5))
            _ = rig.root.advanceFrame(Self.dt)
            let before = Dictionary(uniqueKeysWithValues: Self.panes.map { ($0, rig.terminals[$0]?.pty.applied.count ?? 0) })
            await rig.deliver()
            for pane in Self.panes {
                let pty = try #require(rig.terminals[pane]).pty
                guard pty.applied.count > before[pane, default: 0], frame >= 8 else { continue }
                if lostAt[pane] == nil, !pty.losesNextEcho { lostAt[pane] = frame } else if lostAt[pane] != nil, resumedAt[pane] == nil {
                    resumedAt[pane] = frame
                }
            }
        }
        for pane in Self.panes {
            let lost = try #require(lostAt[pane], "\(pane) applied no grid after frame 8")
            let resumed = try #require(resumedAt[pane], "\(pane) sent no grid after its lost echo")
            #expect(resumed - lost <= ResizeCoordinator.echoWaitFrames + 2,
                    "\(pane) waited \(resumed - lost) frames after a lost echo, more than the echo wait")
        }
        Motion.liveResizeOverride = false
        try await rig.expectSettled(Self.panes, "after the live resize with a lost echo")
    }

    /// Full screen enter and exit, through the window's transition state (`LiveResizeWindows`, as
    /// `willEnterFullScreen` / `didEnterFullScreen` set it) and the coordinator's app hold. Enter sets
    /// the final size at once, as AppKit does (it animates a snapshot to it); exit passes through 12
    /// sizes. No grid goes to a PTY during the transition (the daemon would reflow for sizes nobody
    /// sees); when it ends each terminal's PTY resizes once, to its final frame, draws it, and shows
    /// its prompt at the bottom.
    @Test func fullScreenEnterAndExitResizeEachTerminalOnceAtTheEnd() async throws {
        _ = NSApplication.shared
        let rig = try await Self.filledRig()
        defer { rig.close() }
        defer { Motion.setFullScreenTransitionForTests(rig.window, active: false) }
        let windowed = rig.window.contentLayoutRect.size
        let full = NSSize(width: 2560, height: 1440)
        for (name, target, steps) in [("enter", full, 1), ("exit", windowed, 12)] {
            rig.clearApplied()
            Motion.setFullScreenTransitionForTests(rig.window, active: true)
            #expect(Motion.isFullScreenTransitioning(rig.window))
            let start = rig.window.contentLayoutRect.size
            for step in 1...12 {
                let t = CGFloat(min(step, steps)) / CGFloat(steps)
                rig.resizeWindow(NSSize(width: start.width + (target.width - start.width) * t,
                                        height: start.height + (target.height - start.height) * t))
                _ = rig.root.advanceFrame(Self.dt)
                await rig.deliver()
            }
            for pane in Self.panes {
                let applied = try #require(rig.terminals[pane]).pty.applied
                #expect(applied.isEmpty, "full screen \(name): \(pane)'s PTY resized mid-transition: \(applied)")
            }
            Motion.setFullScreenTransitionForTests(rig.window, active: false)
            try await rig.expectSettled(Self.panes, "full screen \(name)")
            for pane in Self.panes {
                let applied = try #require(rig.terminals[pane]).pty.applied
                #expect(applied.count == 1, "full screen \(name): \(pane)'s PTY resized \(applied.count) times: \(applied)")
            }
        }
    }

    /// A hidden workspace screen (p2 | p3) while the window resizes three times: its terminals do not
    /// resize their PTYs; shown, each resizes once, to the window's current size, and draws it.
    @Test func aHiddenScreenResizesItsTerminalsOnceWhenItShows() async throws {
        _ = NSApplication.shared
        let pair: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))
        let rig = Rig(screens: [Self.screen("s1", .leaf("p1")), Self.screen("s2", pair)], active: "s1")
        defer { rig.close() }
        try rig.attachTerminals(["p1", "p2", "p3"])
        await rig.settle()
        await rig.waitForAnnouncedGrids(["p1"])
        try rig.expectFits("p1", "start")
        rig.clearApplied()
        for size in [NSSize(width: 1500, height: 900), NSSize(width: 800, height: 700), NSSize(width: 1700, height: 1000)] {
            rig.resizeWindow(size)
            await rig.settle()
        }
        for pane: PaneID in ["p2", "p3"] {
            let applied = try #require(rig.terminals[pane]).pty.applied
            #expect(applied.isEmpty, "hidden \(pane) resized its PTY with the window: \(applied)")
        }
        await rig.waitForAnnouncedGrids(["p1"])
        try rig.expectFits("p1", "the shown screen after the resizes")

        rig.model.selectScreen("s2")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        await rig.settle()
        await rig.waitForAnnouncedGrids(["p2", "p3"])
        for pane: PaneID in ["p2", "p3"] {
            let terminal = try #require(rig.terminals[pane])
            #expect(terminal.pty.applied.count == 1,
                    "shown, \(pane) resized its PTY \(terminal.pty.applied.count) times: \(terminal.pty.applied)")
            try rig.expectFits(pane, "s2 shown")
            let container = try #require(rig.provider.containers[pane])
            #expect(container.bounds.width > 800, "shown, \(pane) does not have the wider window's size: \(container.bounds)")
        }
    }
}
