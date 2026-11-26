import Testing
@testable import CmuxMobileTerminal

/// A mirror that holds a window far above the Mac's screen: its rows are the
/// row shift's blank rows, the window, then the Mac's screen. A reader near
/// where the window ends gets newer rows from above, the newest from below.
@Suite struct TerminalHistoryGapTests {
    @Test func theGapIsTheFirstRowPastTheWindow() {
        #expect(TerminalHistoryGap(shift: 110, windowRows: 4_000).row == 4_110)
        #expect(TerminalHistoryGap(shift: -3, windowRows: 4_000).row == 4_000)
    }

    @Test func aReaderNearTheGapNeedsNewerRowsFromAboveAndTheNewestFromBelow() {
        let gap = TerminalHistoryGap(shift: 100, windowRows: 4_000)
        // Reading the middle of the window: nothing.
        #expect(gap.need(visibleTop: 2_000, visibleBottom: 2_040, movingDown: true) == nil)
        // Coming down to within a screen of the window's end.
        #expect(gap.need(visibleTop: 4_030, visibleBottom: 4_070, movingDown: true) == .newer)
        #expect(gap.need(visibleTop: 4_080, visibleBottom: 4_120, movingDown: true) == .newer)
        // Coming up from the Mac's screen to the gap.
        #expect(gap.need(visibleTop: 4_120, visibleBottom: 4_160, movingDown: false) == .newest)
        // On the Mac's screen, well below the gap: nothing.
        #expect(gap.need(visibleTop: 4_300, visibleBottom: 4_340, movingDown: false) == nil)
    }

    /// Simulator run 8f9f55310f87a97be78b36cd: a reader flinging up to line 1
    /// passed near the gap (a replay not yet placed, or the window's end on
    /// the way up) and moved the window back down 40 times, so the page
    /// ended on the Mac's screen instead of line 1. Newer rows are only for a
    /// reader coming down, the newest only for one coming up.
    @Test func onlyAReaderComingDownMovesTheWindowDown() {
        let gap = TerminalHistoryGap(shift: 100, windowRows: 4_000)
        // Going up in the window, near its end: nothing.
        #expect(gap.need(visibleTop: 4_030, visibleBottom: 4_070, movingDown: false) == nil)
        #expect(gap.need(visibleTop: 4_060, visibleBottom: 4_100, movingDown: false) == nil)
        // Going down on the Mac's screen, just below the gap: nothing.
        #expect(gap.need(visibleTop: 4_120, visibleBottom: 4_160, movingDown: true) == nil)
    }

    /// Simulator run ae896fc1853e1768108fe50e: from the Mac's screen a drag
    /// up of a third of the page put the gap mid-page, and nothing was asked.
    /// A reader coming up with rows past the window on screen gets the newest.
    @Test func aReaderComingUpFromTheScreenGetsTheNewestWithTheGapOnThePage() {
        let gap = TerminalHistoryGap(shift: 100, windowRows: 4_000)
        #expect(gap.need(visibleTop: 4_085, visibleBottom: 4_125, movingDown: false) == .newest)
        #expect(gap.need(visibleTop: 4_062, visibleBottom: 4_102, movingDown: false) == .newest)
    }
}
