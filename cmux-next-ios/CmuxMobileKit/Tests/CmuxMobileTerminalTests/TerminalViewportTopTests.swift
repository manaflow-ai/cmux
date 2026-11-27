import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// termqa N3 (VERIFY-round11 B10): `seq 1 300; printf '\e[7m%*s\e[0m' $COLUMNS ''; read x`
/// left the bar (the cursor's row, no text) under the composer while the pin
/// log said gap 0.
@Suite struct TerminalViewportTopTests {
    /// 151-row grid. The page followed the end with a request for row 149
    /// (Ghostty's active top then: 300 rows), so Ghostty's viewport follows
    /// the active area. One more row arrives and is reported (301 rows,
    /// viewport 150). The cursor on the viewport's last row is row 300, not
    /// 299, and the document keeps that row.
    @Test func aFollowedViewportReadsTheCursorFromTheNewerReport() {
        var top = TerminalViewportTop()
        top.request(149)
        top.report()
        let cursor = top.cursorRow(viewportRow: 150, reportedOffset: 150, totalRows: 301, gridRows: 151)
        #expect(cursor == 300)
        let layout = TerminalDocumentLayout.make(totalRows: 301, cursorRow: cursor, leadingBlankRows: 0)
        #expect(layout.endRow == 301)
    }

    /// A request sent after the last report is Ghostty's viewport (the
    /// report for it is still to come).
    @Test func aRequestNewerThanTheReportIsTheViewport() {
        var top = TerminalViewportTop()
        top.report()
        top.request(100)
        #expect(top.cursorRow(viewportRow: 5, reportedOffset: 150, totalRows: 301, gridRows: 151) == 105)
        // A request inside the active area follows it.
        top.request(400)
        #expect(top.cursorRow(viewportRow: 5, reportedOffset: 150, totalRows: 301, gridRows: 151) == 155)
    }

    /// Before any request the report is the viewport (a reading page whose
    /// viewport was moved by Ghostty, e.g. a reset).
    @Test func withoutARequestTheReportIsTheViewport() {
        let top = TerminalViewportTop()
        #expect(top.cursorRow(viewportRow: 3, reportedOffset: 40, totalRows: 301, gridRows: 151) == 43)
    }

    /// A prune renumbers the rows: a pending request moves up with them.
    @Test func aPruneMovesThePendingRequest() {
        var top = TerminalViewportTop()
        top.request(100)
        top.shiftRows(by: -10)
        #expect(top.requestedRow == 90)
        #expect(top.cursorRow(viewportRow: 5, reportedOffset: 150, totalRows: 291, gridRows: 151) == 95)
    }

    /// The pin log measures the drawn cursor row too: a cursor row drawn one
    /// row below the document's end is 16 pt under the card, not gap 0.
    @Test func thePinGapCountsTheDrawnCursorRow() {
        #expect(TerminalDocumentLayout.drawnGap(composerTop: 458, lastRowBottom: 458, cursorRowBottom: 474) == -16)
        #expect(TerminalDocumentLayout.drawnGap(composerTop: 458, lastRowBottom: 458, cursorRowBottom: 442) == 0)
        #expect(TerminalDocumentLayout.drawnGap(composerTop: 458, lastRowBottom: 440, cursorRowBottom: nil) == 18)
    }
}
