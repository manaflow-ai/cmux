import CoreGraphics
@testable import CmuxNextTerminal
import Testing

/// `debug.terminal_display`'s per-terminal count (bench-terminal-resize.py fails a drag or key resize with a held frame):
/// a frame is held when the host asked another size than the pane's, lagging when the layer shows another size.
struct TerminalPaneFollowTallyTests {
    static func sizes(area: CGFloat, asked: CGFloat, shown: CGFloat) -> TerminalPaneFollowSizes {
        TerminalPaneFollowSizes(area: CGSize(width: area, height: 400), asked: CGSize(width: asked, height: 400),
                                shown: CGSize(width: shown, height: 400))
    }

    @Test func aTerminalThatFollowsItsPaneHasNoHeldOrLaggingFrame() {
        var tally = TerminalPaneFollowTally()
        for (frame, width) in [600.0, 590, 580].enumerated() {
            // Half a point off is the same size (fractional layout).
            tally.record(Self.sizes(area: width, asked: width + 0.5, shown: width - 0.5), frame: frame)
        }
        #expect(tally.frames == 3)
        #expect(tally.held == 0 && tally.lagging == 0)
        #expect(tally.firstHeld.isEmpty && tally.firstLagging.isEmpty)
    }

    @Test func aHeldSurfaceCountsEveryFrameItKeepsAnotherSizeAndKeepsTheFirstThree() {
        var tally = TerminalPaneFollowTally()
        // A drag hold: the surface keeps 600 while its pane narrows.
        for (frame, width) in [600.0, 590, 580, 570, 560].enumerated() {
            tally.record(Self.sizes(area: width, asked: 600, shown: 600), frame: frame)
        }
        #expect(tally.frames == 5)
        #expect(tally.held == 4)
        #expect(tally.lagging == 4)
        #expect(tally.firstHeld.map(\.frame) == [1, 2, 3])
        #expect(tally.firstHeld.first?.sizes == Self.sizes(area: 590, asked: 600, shown: 600))
    }

    @Test func aLayerOneFrameBehindIsLaggingNotHeld() {
        var tally = TerminalPaneFollowTally()
        // The frame owner asks the pane's size at once and shows it a frame later.
        tally.record(Self.sizes(area: 590, asked: 590, shown: 600), frame: 0)
        tally.record(Self.sizes(area: 580, asked: 580, shown: 590), frame: 1)
        tally.record(Self.sizes(area: 580, asked: 580, shown: 580), frame: 2)
        #expect(tally.held == 0)
        #expect(tally.lagging == 2)
        #expect(tally.firstLagging.map(\.frame) == [0, 1])
    }
}
