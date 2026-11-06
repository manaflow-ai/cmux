import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import struct CmuxNextDaemon.CellSize
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import Testing

/// cmux-ad m18/m29: during a person's divider or column-edge drag, the program in each terminal gets its new size while
/// the drag moves, coalesced as Ghostty.app does (`TerminalGridReportCoalescer`: the first new grid opens a 25 ms window,
/// later grids replace it, the newest goes when it closes), and the release's grid goes when the release lands. Before
/// (feat at 058a07e4ae1): one grid per drag, at the landing. A full-screen program (the alternate screen, which the
/// reflow preview does not re-wrap) stayed at its start size for the whole drag, the terminal background beside it, then
/// jumped at the mouse-up (the RESIZE OWNER's film of px-col-drag-2-sw-terminals at 96ad37a03a3, STATUS 14461). Still
/// never one grid per frame: the program redraws at most once per window.
/// Real terminal sessions and the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test steps the frames
/// and the coalescer's clock: each terminal's grid reporter runs on a `ManualClock`, advanced 12 ms per drag frame, so the
/// 25 ms windows close as in a drag with no real sleep (review of #36631: a loaded runner stretched the real sleeps).
@MainActor
@Suite(.closesItsWindows, .timeLimit(.minutes(1)))
struct DividerDragTerminalResizeCountTests {
    typealias Harness = SplitTerminalResizeCountTests

    @Test func aDividerDragResizesEachPTYWhileItMovesCoalescedAndAtTheLanding() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        let clock = ManualClock()
        for terminal in screen.terminals.values {
            let view = terminal.session.surfaceView
            view.gridReports = TerminalGridReporter(view: view, clock: clock)
            terminal.pty.applied.removeAll()
        }
        let before = try #require(screen.terminals["p1"]?.session.surfaceView.fittedGrid)

        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        // 40 frames of 6 pt, 12 ms apart (about half a second): the divider crosses many cells of both terminals.
        let moves = 40
        for step in 1...moves {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 6, y: start.y), []))
            screen.root.syncWithModel()
            await screen.step()
            // The drag's own pace: a window that opened waits on the clock, then 12 ms pass.
            if screen.terminals.values.contains(where: { $0.session.surfaceView.gridReports.isWaiting }), clock.sleeperCount == 0 {
                try await clock.waitForSleeper()
            }
            clock.advance(by: .milliseconds(12))
            for _ in 0..<20 { await Task.yield() }
        }
        await screen.drain()
        let midDrag = screen.terminals.mapValues(\.pty.applied)
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the release never landed")
        await screen.drain()

        for pane: PaneID in ["p1", "p2"] {
            let terminal = try #require(screen.terminals[pane])
            let during = midDrag[pane] ?? []
            #expect(during.count >= 2, "\(pane): its PTY got \(during.count) grids while the drag moved: it waits for the landing (\(during))")
            #expect(during.count <= moves / 2, "\(pane): \(during.count) PTY grids in \(moves) drag frames: one per frame, not coalesced")
            #expect(zip(during, during.dropFirst()).allSatisfy { $0 != $1 }, "\(pane): the same grid twice in a row: \(during)")
            let applied = terminal.pty.applied
            if let grid = terminal.session.surfaceView.fittedGrid, let last = applied.last {
                #expect(last == CellSize(cols: grid.columns, rows: grid.rows), "\(pane): the PTY rests at \(last), the view fits \(grid)")
            }
        }
        let after = try #require(screen.terminals["p1"]?.session.surfaceView.fittedGrid)
        #expect(after.columns < before.columns - 10, "the drag narrowed p1 (\(before.columns) -> \(after.columns) columns)")
    }

    /// The RESIZE OWNER's film of px-col-drag-2 on build 155b3f25 (STATUS 15707): after a fast drag's mouse-up the
    /// full-screen program was whole only 4 refreshes after its pane rested. One of them: the drag's last grid waited in
    /// the coalescer's window until the release landed, the frame tick after the mouse-up. The person let go: the grid
    /// that waits goes in the mouse-up turn, not a frame (or a 25 ms window) later. The clock never moves here, so only
    /// that release can send it.
    @Test func aDragsLastGridGoesInTheMouseUpTurn() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        let clock = ManualClock()
        for terminal in screen.terminals.values {
            let view = terminal.session.surfaceView
            view.gridReports = TerminalGridReporter(view: view, clock: clock)
        }
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        for step in 1...6 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 12, y: start.y), []))
            screen.root.syncWithModel()
            await screen.step()
        }
        let left = try #require(screen.terminals["p1"]?.session.surfaceView)
        try #require(left.gridReports.isWaiting, "p1's last drag grid does not wait in the coalescer: the case under test did not happen")
        // The mouse-up, at the last point: its turn, no frame after it, no time on the clock.
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 72, y: start.y), []))
        for (pane, terminal) in screen.terminals {
            let surface = terminal.session.surfaceView
            #expect(!surface.gridReports.isWaiting, "\(pane): its last drag grid still waits after the mouse-up (a frame or 25 ms more)")
            #expect(surface.gridReports.coalescer.lastSent == surface.fittedGrid,
                    "\(pane): the program has \(String(describing: surface.gridReports.coalescer.lastSent)), the view fits \(String(describing: surface.fittedGrid))")
        }
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        await screen.drain()
        let applied = try #require(screen.terminals["p1"]).pty.applied
        if let grid = left.fittedGrid, let last = applied.last {
            #expect(last == CellSize(cols: grid.columns, rows: grid.rows), "p1: the PTY rests at \(last), the view fits \(grid)")
        }
    }
}
