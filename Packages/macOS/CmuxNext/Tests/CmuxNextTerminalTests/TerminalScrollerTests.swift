import AppKit
@testable import CmuxNextTerminal
import Testing

/// The terminal's scroller hears its own clip move from the clip (p03-rendering-039), not from a
/// `boundsDidChangeNotification` observer: a scroller drag reports the row it shows, and the
/// scroller's own placement for Ghostty's scrollbar reports nothing back.
@MainActor
struct TerminalScrollerTests {
    private func scroller() -> TerminalScroller {
        let scroller = TerminalScroller()
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 100)
        scroller.tile()
        return scroller
    }

    @Test func aClipMoveReportsTheRowAtTheTop() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(TerminalScrollbar(totalRows: 100, offsetRows: 90, visibleRows: 10))
        #expect(rows.isEmpty, "placing the knob for Ghostty's scrollbar is not a user move")
        // Ten points a row: a 100 pt viewport shows 10 rows.
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 400))
        #expect(rows == [40])
    }

    @Test func anUpdateThatMovesTheViewportReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(TerminalScrollbar(totalRows: 100, offsetRows: 90, visibleRows: 10))
        scroller.update(TerminalScrollbar(totalRows: 100, offsetRows: 20, visibleRows: 10))
        #expect(scroller.contentView.bounds.origin.y == 200)
        #expect(rows.isEmpty)
    }

    @Test func aMoveToTheRowAlreadyShownReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(TerminalScrollbar(totalRows: 100, offsetRows: 30, visibleRows: 10))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 301)) // rounds to row 30
        #expect(rows.isEmpty)
    }
}
