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
        #expect(gap.need(visibleTop: 2_000, visibleBottom: 2_040) == nil)
        // Coming down to within a screen of the window's end.
        #expect(gap.need(visibleTop: 4_030, visibleBottom: 4_070) == .newer)
        #expect(gap.need(visibleTop: 4_080, visibleBottom: 4_120) == .newer)
        // Coming up from the Mac's screen to the gap.
        #expect(gap.need(visibleTop: 4_120, visibleBottom: 4_160) == .newest)
        // On the Mac's screen, well below the gap: nothing.
        #expect(gap.need(visibleTop: 4_300, visibleBottom: 4_340) == nil)
    }
}
