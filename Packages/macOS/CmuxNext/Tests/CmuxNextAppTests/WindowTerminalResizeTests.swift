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
import Testing

/// Window resize with real terminals (Lawrence 2026-10-27: "we need resize tests, for both windows, and
/// panes too"; resizing the window made the terminal look broken). Each pane holds a real
/// ``TerminalSession`` on libghostty. Its IO is the app's daemon IO as far as grids go: every grid the
/// view reports goes to the `ResizeCoordinator`, the coordinator applies it to the PTY, and the PTY
/// announces it back (`.resize`, as the daemon does once the PTY has the size), which locks the grid
/// the surface draws. After every window size, settled, every visible pane's terminal fits its pane:
/// its surface has the pane's size, the grid is what fits at the font's cell size, the PTY holds that
/// grid with the pixel size of that many cells, and the surface draws that grid, not the old one.
@MainActor @Suite(.serialized)
struct WindowTerminalResizeTests {
    /// The PTY a resize reaches (`DaemonTerminalIO.applySettled`); it announces each size back.
    final class PTY: ResizeTarget {
        static let marker = Data("\u{1}flush\u{1}".utf8)
        var applied: [CellSize] = []
        /// The pixel sizes the view sent with its grids, in order.
        var pixels: [CGSize] = []
        var awaitsEcho: Bool { false }
        var announce: ((CellSize) -> Void)?
        /// The terminal's window, for its full screen hold (the app passes the view's window).
        weak var window: NSWindow?
        func applySettled(_ size: CellSize) {
            applied.append(size)
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

    struct Terminal {
        let session: TerminalSession
        let io: CoordinatedIO
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

    /// The coordinator runs only on the test's frames, and holds a window in a full screen transition.
    final class Holds {
        var open = false
        var transitioning: Set<ObjectIdentifier> = []
    }

    static let dt = 1.0 / 120
    /// p1 | (p2 / p3).
    static let nested: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                          b: .split("d", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let holds: Holds
        let coordinator: ResizeCoordinator
        var terminals: [PaneID: Terminal] = [:]
        /// The font's cell in pixels, from the first terminal: no resize changes it.
        var cell: CGSize?

        init(screens: [LayoutScreen], active: ScreenID, size: NSSize = NSSize(width: 1200, height: 800)) {
            let holds = Holds()
            self.holds = holds
            coordinator = ResizeCoordinator(holds: { window in
                !holds.open || window.map { holds.transitioning.contains(ObjectIdentifier($0)) } ?? false
            })
            model = LayoutModel(screens: screens, activeScreenID: active, focusedPane: nil)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
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
            terminals[pane] = Terminal(session: session, io: io)
        }

        /// Every grid reported so far reaches the coordinator, then it runs one frame.
        func deliver() async {
            for terminal in terminals.values { await terminal.pty.flush(terminal.session) }
            holds.open = true
            _ = coordinator.tick()
            holds.open = false
        }

        /// Frames until the layout rests and the coordinator has nothing left to send.
        func settle() async {
            for _ in 1...240 {
                let moving = root.advanceFrame(WindowTerminalResizeTests.dt)
                await deliver()
                if !moving && coordinator.isIdle { break }
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

        func close() {
            for terminal in terminals.values {
                terminal.session.close()
                terminal.io.finish()
            }
            window.close()
        }
    }

    static func screen(_ id: ScreenID, _ tree: SplitNode) -> LayoutScreen {
        LayoutScreen(id: id, name: id.rawValue, layout: .splits(tree))
    }

    static let sizes: [NSSize] = [
        NSSize(width: 1600, height: 1000), NSSize(width: 900, height: 600), NSSize(width: 2400, height: 1400),
        NSSize(width: 480, height: 320), NSSize(width: 1201, height: 799), NSSize(width: 1200, height: 800),
    ]

    /// A window resize to each size (grow, shrink, very large, small, off by a point), settled: every
    /// pane's terminal of p1 | (p2 / p3) fits its new frame, its PTY holds that grid, and it draws it.
    @Test func aWindowResizeResizesEveryPaneTerminalToItsFrame() async throws {
        _ = NSApplication.shared
        let rig = Rig(screens: [Self.screen("s", Self.nested)], active: "s")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        for pane in panes { try rig.attachTerminal(pane) }
        await rig.settle()
        await rig.waitForAnnouncedGrids(panes)
        for pane in panes { try rig.expectFits(pane, "start") }
        for size in Self.sizes {
            rig.resizeWindow(size)
            await rig.settle()
            await rig.waitForAnnouncedGrids(panes)
            for pane in panes { try rig.expectFits(pane, "window \(Int(size.width))x\(Int(size.height))") }
        }
    }

    /// A live resize: the window edge moves every frame for 60 frames, out and back. Each frame's grid
    /// goes to the PTY the next frame (no hold), and when the drag stops every terminal fits its final
    /// frame and draws that grid, not one from the middle of the drag.
    @Test func aLiveResizeEndsWithEveryTerminalOnItsFinalFrame() async throws {
        _ = NSApplication.shared
        Motion.liveResizeOverride = true
        defer { Motion.liveResizeOverride = nil }
        let rig = Rig(screens: [Self.screen("s", Self.nested)], active: "s")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        for pane in panes { try rig.attachTerminal(pane) }
        await rig.settle()
        rig.clearApplied()
        for frame in 0..<60 {
            let out = frame < 30 ? frame : 60 - frame
            rig.resizeWindow(NSSize(width: 1200 + CGFloat(out) * 17, height: 800 + CGFloat(out) * 7))
            _ = rig.root.advanceFrame(Self.dt)
            await rig.deliver()
        }
        #expect(rig.terminals.values.allSatisfy { !$0.pty.applied.isEmpty }, "a live resize sent no grid until it ended")
        rig.resizeWindow(NSSize(width: 1333, height: 777))
        Motion.liveResizeOverride = false
        await rig.settle()
        await rig.waitForAnnouncedGrids(panes)
        for pane in panes { try rig.expectFits(pane, "after the live resize") }
    }

    /// Full screen enter and exit: the window takes its full screen size over the animation's frames.
    /// No grid goes to a PTY during the transition (the daemon would reflow for sizes the animation
    /// passes through); when it ends each terminal's PTY resizes once, to its final frame, and draws it.
    @Test func fullScreenEnterAndExitResizeEachTerminalOnceAtTheEnd() async throws {
        _ = NSApplication.shared
        let rig = Rig(screens: [Self.screen("s", Self.nested)], active: "s")
        defer { rig.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        for pane in panes { try rig.attachTerminal(pane) }
        await rig.settle()
        await rig.waitForAnnouncedGrids(panes)
        let windowed = rig.window.contentLayoutRect.size
        for (name, target) in [("enter", NSSize(width: 2560, height: 1440)), ("exit", windowed)] {
            rig.clearApplied()
            rig.holds.transitioning.insert(ObjectIdentifier(rig.window))
            let start = rig.window.contentLayoutRect.size
            for step in 1...12 {
                let t = CGFloat(step) / 12
                rig.resizeWindow(NSSize(width: start.width + (target.width - start.width) * t,
                                        height: start.height + (target.height - start.height) * t))
                _ = rig.root.advanceFrame(Self.dt)
                await rig.deliver()
            }
            for pane in panes {
                let applied = try #require(rig.terminals[pane]).pty.applied
                #expect(applied.isEmpty, "full screen \(name): \(pane)'s PTY resized mid-transition: \(applied)")
            }
            rig.holds.transitioning.removeAll()
            await rig.settle()
            await rig.waitForAnnouncedGrids(panes)
            for pane in panes {
                let applied = try #require(rig.terminals[pane]).pty.applied
                #expect(applied.count == 1, "full screen \(name): \(pane)'s PTY resized \(applied.count) times: \(applied)")
                try rig.expectFits(pane, "full screen \(name)")
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
        for pane: PaneID in ["p1", "p2", "p3"] { try rig.attachTerminal(pane) }
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
