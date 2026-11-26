#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-25: "When I tap the composer at certain points it treats it as if I also
/// simultaneously tapped one of the combo buttons which needs to be fixed". The 8 pt between
/// the key row and the composer is the composer's (`TerminalBottomStack.composerGap`).
@Suite struct TerminalComposerGapTests {
    let keyRow = CGRect(x: 0, y: 0, width: 402, height: TerminalDockMetrics.keyRowHeight)

    @Test func theGapSpansTheWidthBetweenTheRowAndTheComposer() {
        let composer = CGRect(x: 0, y: keyRow.maxY + TerminalDockMetrics.keyRowGap, width: 402, height: 60)
        let gap = TerminalBottomStack.gap(below: keyRow, above: composer, width: 402)
        #expect(gap == CGRect(x: 0, y: keyRow.maxY, width: 402, height: TerminalDockMetrics.keyRowGap))
        #expect(gap?.contains(CGPoint(x: 1, y: keyRow.maxY + 4)) == true)
        #expect(gap?.contains(CGPoint(x: 200, y: keyRow.maxY - 1)) == false)
    }

    @Test func noGapWhenTheyTouch() {
        let composer = CGRect(x: 0, y: keyRow.maxY, width: 402, height: 60)
        #expect(TerminalBottomStack.gap(below: keyRow, above: composer, width: 402) == nil)
    }
}
#endif
