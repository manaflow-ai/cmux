import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
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
/// Real terminal sessions and the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test steps the frames,
/// and real time passes between them (12 ms per frame) so the coalescer's windows close as in a drag.
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
        for terminal in screen.terminals.values { terminal.pty.applied.removeAll() }
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
            try await Task.sleep(for: .milliseconds(12)) // the drag's own pace: the coalescer's 25 ms windows close
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
}
