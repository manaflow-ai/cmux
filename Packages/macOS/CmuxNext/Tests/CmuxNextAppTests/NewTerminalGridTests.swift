import CoreGraphics
import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Testing
@testable import CmuxNextApp

/// A new terminal tab spawns at the grid its view will fit, so the first
/// frame is already the final size (the user saw a frame at the wrong size).
/// The estimate must equal what Ghostty fits into the same view, or the
/// view's first report resizes the PTY and the pane snaps.
@MainActor @Suite struct NewTerminalGridTests {
    /// cmux's default padding; `TerminalPadding`'s memberwise init is internal.
    private let padding: TerminalPadding = {
        var padding = TerminalPadding.cmuxDefault
        padding.leading = 6; padding.trailing = 7; padding.top = 5; padding.bottom = 6.5
        return padding
    }()

    /// Ghostty's own fit (``TerminalGridMetrics``) of a surface of `points` at `scale`.
    private func ghosttyFit(width: Double, height: Double, scale: Double, cell: (Int, Int), padding: TerminalPadding) -> TerminalGridSize {
        let pad = { (points: CGFloat) in Int((Double(points) * scale).rounded(.down)) }
        let metrics = TerminalGridMetrics(cellWidth: cell.0, cellHeight: cell.1,
                                          paddingWidth: pad(padding.leading) + pad(padding.trailing),
                                          paddingHeight: pad(padding.top) + pad(padding.bottom))
        return metrics.grid(fittingWidth: Int((width * scale).rounded()), height: Int((height * scale).rounded()))
    }

    @Test(arguments: [
        (width: 800.0, height: 600.0, scale: 2.0),
        (width: 1203.5, height: 817.0, scale: 2.0),
        (width: 640.0, height: 400.0, scale: 1.0),
        (width: 333.0, height: 120.0, scale: 3.0),
    ])
    func paneSizeEstimateMatchesGhosttysFit(width: Double, height: Double, scale: Double) {
        let cell = (16, 34)
        let choice = NewTerminalGrid(shownTerminalGrid: nil, hostSize: CGSize(width: width, height: height), scale: scale,
                                     cellPixels: CGSize(width: cell.0, height: cell.1), padding: padding,
                                     surfaceWidth: { $0 })
        #expect(choice.grid == ghosttyFit(width: width, height: height, scale: scale, cell: cell, padding: padding))
    }

    @Test func shownTerminalsOwnFitWins() {
        let shown = TerminalGridSize(columns: 97, rows: 31)
        let choice = NewTerminalGrid(shownTerminalGrid: shown, hostSize: CGSize(width: 10, height: 10), scale: 2,
                                     cellPixels: CGSize(width: 16, height: 34), padding: padding, surfaceWidth: { $0 })
        #expect(choice.grid == shown)
    }

    @Test func aLegacyScrollerStripIsNotTerminalWidth() {
        let choice = NewTerminalGrid(shownTerminalGrid: nil, hostSize: CGSize(width: 800, height: 600), scale: 2,
                                     cellPixels: CGSize(width: 16, height: 34), padding: padding,
                                     surfaceWidth: { $0 - 15 })
        #expect(choice.grid == ghosttyFit(width: 785, height: 600, scale: 2, cell: (16, 34), padding: padding))
    }

    @Test func unknownCellsOrNoWindowLetTheDaemonChoose() {
        let noCells = NewTerminalGrid(shownTerminalGrid: nil, hostSize: CGSize(width: 800, height: 600), scale: 2,
                                      cellPixels: nil, padding: padding)
        let noWindow = NewTerminalGrid(shownTerminalGrid: nil, hostSize: CGSize(width: 800, height: 600), scale: nil,
                                       cellPixels: CGSize(width: 16, height: 34), padding: padding)
        let empty = NewTerminalGrid(shownTerminalGrid: nil, hostSize: .zero, scale: 2,
                                    cellPixels: CGSize(width: 16, height: 34), padding: padding)
        #expect(noCells.grid == nil)
        #expect(noWindow.grid == nil)
        #expect(empty.grid == nil)
    }

    /// The first frame's grid is the final grid: a view that fits the spawn
    /// grid reports nothing new, so the PTY is never resized after spawn.
    @Test func aViewFittingTheSpawnGridNeverResizesThePTY() throws {
        let choice = NewTerminalGrid(shownTerminalGrid: nil, hostSize: CGSize(width: 1000, height: 700), scale: 2,
                                     cellPixels: CGSize(width: 16, height: 34), padding: padding, surfaceWidth: { $0 })
        let spawned = try #require(choice.grid)
        var policy = TerminalGridPolicy(ownsGeometry: true)
        policy.announce(spawned) // the daemon's first `.resize`: the PTY's grid at spawn
        let viewFit = ghosttyFit(width: 1000, height: 700, scale: 2, cell: (16, 34), padding: padding)
        _ = policy.viewSized(viewFit)
        #expect(policy.rendered == viewFit) // the first frame already draws the view's own grid
        #expect(policy.announced == policy.desired) // nothing left for the daemon to apply
    }
}
