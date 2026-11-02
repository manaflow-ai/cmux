import AppKit
import CmuxNextBridge
import struct CmuxNextDaemon.CellSize
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import QuartzCore
import Testing

/// A divider drag whose release springs (the release lands the divider away from the last drag frame: a resampled
/// last frame, a fling onto a snap) still resizes each terminal's PTY once, at the grid its view fits when it lands.
/// Review of the #32006 dogfood port: the drag holds each surface at its drag-start size, and the release's spring
/// measured its rest size as that held size plus the content area's change against its live size, so the spring's
/// start sent a grid no frame rests at, and the landing sent a second one (two SIGWINCH, two reflows).
/// Real terminal sessions behind the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test is the clock.
@MainActor
@Suite(.serialized)
struct DividerDragSpringReleaseTerminalResizeTests {
    typealias Harness = SplitTerminalResizeCountTests

    @Test func aDragWhoseReleaseSpringsResizesEachPTYOnceAtTheLandedGrid() async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        for terminal in screen.terminals.values { terminal.pty.applied.removeAll() }

        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start))
        for step in 1...30 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), time: CACurrentMediaTime()))
            screen.root.syncWithModel()
            await screen.step()
        }
        // The release lands 80 pt left of the last drag frame: the divider springs there.
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 320, y: start.y), time: CACurrentMediaTime()))
        screen.root.syncWithModel()
        var moving = await screen.step()
        #expect(moving, "the release did not spring")
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the release never landed")
        await screen.drain()

        for pane: PaneID in ["p1", "p2"] {
            let terminal = try #require(screen.terminals[pane])
            let applied = terminal.pty.applied
            #expect(applied.count == 1, "\(pane): \(applied.count) PTY resizes for one divider drag: \(applied)")
            if let grid = terminal.session.surfaceView.fittedGrid, let last = applied.last {
                #expect(last == CellSize(cols: grid.columns, rows: grid.rows), "\(pane): the PTY rests at \(last), the view fits \(grid)")
            }
        }
    }
}
