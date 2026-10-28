import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// A terminal in a pane one cell big (handoff pane-min.md): Ghostty sizes it to a grid of at least one column and
/// one row with no error, the PTY gets exactly that grid, and the grid grows back when the pane does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalSmallGridTests {
    /// The grids the session reported, in order (the PTY side's view of them).
    @MainActor final class Grids {
        var reported: [TerminalGridSize] = []
    }

    /// Takes every grid on the main actor, in the report's own turn, as the app's daemon IO does.
    nonisolated final class GridIO: TerminalIO {
        let events: AsyncStream<TerminalIOEvent>
        private let end: AsyncStream<TerminalIOEvent>.Continuation
        let grids: Grids

        init(grids: Grids) {
            (events, end) = AsyncStream<TerminalIOEvent>.makeStream()
            self.grids = grids
        }

        func finish() { end.finish() }
        func write(_ data: Data) async {}
        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

        @MainActor func resizeOnMain(cols: Int, rows: Int, final: Bool, window: NSWindow?) -> Bool {
            grids.reported.append(TerminalGridSize(columns: cols, rows: rows))
            return true
        }
    }

    @Test func aOneCellPaneGivesThePTYAOneByOneGridThatGrowsBack() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let grids = Grids()
        let io = GridIO(grids: grids)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            session.close()
            io.finish()
            window.close()
        }
        let surface = try #require(session.surfaceView.surface, "libghostty created no surface")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container
        session.view.frame = container.bounds
        container.addSubview(session.view)
        window.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        session.view.layoutSubtreeIfNeeded()
        let wide = try #require(grids.reported.last, "no grid at 640 x 320")
        #expect(wide.columns > 20 && wide.rows > 5, "\(wide)")
        for size in [CGSize(width: 12, height: 20), CGSize(width: 8, height: 16), CGSize(width: 2, height: 2)] {
            session.view.frame = NSRect(origin: .zero, size: size)
            session.view.layoutSubtreeIfNeeded()
            let grid = try #require(grids.reported.last)
            let fits = ghostty_surface_size(surface)
            #expect(grid.columns >= 1 && grid.rows >= 1, "\(size): \(grid)")
            #expect(Int(fits.columns) == grid.columns && Int(fits.rows) == grid.rows, "\(size): the PTY has \(grid), Ghostty fits \(fits.columns)x\(fits.rows)")
            #expect(grid.columns <= 2 && grid.rows <= 2, "\(size): \(grid)")
        }
        session.view.frame = container.bounds
        session.view.layoutSubtreeIfNeeded()
        #expect(grids.reported.last == wide, "the grid grows back: \(String(describing: grids.reported.last)) vs \(wide)")
    }
}
