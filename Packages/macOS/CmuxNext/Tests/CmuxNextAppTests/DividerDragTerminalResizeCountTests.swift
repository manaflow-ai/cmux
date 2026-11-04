import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import struct CmuxNextDaemon.CellSize
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A person's divider drag resizes each terminal's PTY once, when the drag lands, not once per cell the
/// divider crosses (RESIZE VIDEOS, Lawrence 2026-11-02: "terminals reflow once at the end, one SIGWINCH,
/// never garbage mid-animation"). The frames follow the pointer with no spring, so the terminals reported a
/// grid on every drag event: the program in each one (htop, vim, a TUI that redraws on SIGWINCH) redrew at
/// every size while the daemon's announcements came a round trip behind the view, torn rows mid-drag.
/// Through the drag a terminal now draws its grid reflowed to the pane locally (the reflow preview, as in a
/// split's spring) and sends one grid when the drag's release lands, as a Chromium page lays out once.
/// Real terminal sessions and the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test is the clock.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragTerminalResizeCountTests {
    typealias Harness = SplitTerminalResizeCountTests

    @Test func aDividerDragResizesEachPTYOnceWhenItLands() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        for terminal in screen.terminals.values { terminal.pty.applied.removeAll() }
        let before = try #require(screen.terminals["p1"]?.session.surfaceView.fittedGrid)

        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        // 30 drag events, 8 pt each: the divider crosses many cells of both terminals.
        for step in 1...30 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await screen.step()
        }
        let midDrag = screen.terminals.mapValues(\.pty.applied.count)
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 240, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the release never landed")
        await screen.drain()

        #expect(midDrag.values.allSatisfy { $0 == 0 }, "PTY resizes during the drag: \(midDrag)")
        for pane: PaneID in ["p1", "p2"] {
            let terminal = try #require(screen.terminals[pane])
            let applied = terminal.pty.applied
            #expect(applied.count == 1, "\(pane): \(applied.count) PTY resizes for one divider drag: \(applied)")
            if let grid = terminal.session.surfaceView.fittedGrid, let last = applied.last {
                #expect(last == CellSize(cols: grid.columns, rows: grid.rows), "\(pane): the PTY rests at \(last), the view fits \(grid)")
            }
        }
        let after = try #require(screen.terminals["p1"]?.session.surfaceView.fittedGrid)
        #expect(after.columns < before.columns - 10, "the drag narrowed p1 (\(before.columns) -> \(after.columns) columns)")
    }
}
