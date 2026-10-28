import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// The terminal's scroller hears its own clip move from the clip, not from a
/// NotificationCenter observer of the clip: a scroller drag reports the row it shows, and the
/// scroller's own placement for Ghostty's scrollbar reports nothing back. It places each scrollbar
/// the host delivers at once (the host's FrameObservation coalesces output to one per
/// frame), and a drag move is compared with the row the terminal is going to.
@MainActor
struct TerminalScrollerTests {
    private func scroller() -> TerminalScroller {
        let scroller = TerminalScroller()
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 100)
        scroller.tile()
        return scroller
    }

    private static func bar(_ offset: UInt64) -> TerminalScrollbar {
        TerminalScrollbar(totalRows: 100, offsetRows: offset, visibleRows: 10)
    }

    @Test func theClipIsTheSharedGeometryClip() {
        let scroller = scroller()
        #expect(scroller.contentView is ScrollGeometryClipView)
        #expect(ScrollGeometryClipView.install(in: scroller) === scroller.contentView, "a later client keeps the clip")
    }

    @Test func aClipMoveReportsTheRowAtTheTop() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90))
        #expect(rows.isEmpty, "placing the knob for Ghostty's scrollbar is not a user move")
        // Ten points a row: a 100 pt viewport shows 10 rows.
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 400))
        #expect(rows == [40])
    }

    @Test func anUpdateThatMovesTheViewportReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90))
        scroller.update(Self.bar(20))
        #expect(scroller.contentView.bounds.origin.y == 200)
        #expect(rows.isEmpty)
    }

    @Test func aMoveToTheRowAlreadyShownReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(30))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 301)) // rounds to row 30
        #expect(rows.isEmpty)
    }

    /// Two of a person's scrolls in one display frame (a 120 Hz trackpad on a 60 Hz display): each
    /// places the knob in its own turn, with no frame in between, so the knob never lags the content.
    @Test func eachUpdatePlacesTheKnobAtOnce() {
        let scroller = scroller()
        scroller.update(Self.bar(90))
        scroller.update(Self.bar(50))
        #expect(scroller.knobPlacements == 2)
        #expect(scroller.shown == Self.bar(50), "the second update waited")
        #expect(scroller.contentView.bounds.origin.y == 500)
    }

    /// A layout at the placed clip size (the scroller's own document change) places nothing; a new
    /// clip size places the knob for it.
    @Test func onlyANewClipSizePlacesTheKnobOnLayout() {
        let scroller = scroller()
        scroller.update(Self.bar(0))
        #expect(scroller.knobPlacements == 1)
        scroller.layout()
        #expect(scroller.knobPlacements == 1, "a layout at the placed clip size placed the knob")
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 200)
        scroller.tile()
        scroller.layout()
        #expect(scroller.knobPlacements == 2, "a new clip size did not place the knob")
        // Twenty points a row now: the document stands for 100 rows.
        #expect(scroller.documentView?.frame.height == 2000)
    }

    /// The window or the pane grows while the terminal shows the bottom of a long scrollback: the
    /// clip gets taller than what is left of the document, and AppKit clamps its origin into the
    /// document. That move is the scroll view's own layout, not a person's scroll. Before the fix the
    /// scroller reported it as a row above the bottom, and Ghostty scrolled the terminal into its
    /// history with the prompt out of view, further at each grow step (dogfood of chrome-parity-v1,
    /// 2026-10-27: "resizing window makes terminal looks buggy").
    @Test func aTallerClipAtTheBottomAsksForNoRow() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90)) // the bottom: rows 90 to 99 of 100
        for height: CGFloat in [150, 200, 400] {
            scroller.frame = NSRect(x: 0, y: 0, width: 12, height: height)
            scroller.tile()
            scroller.layout()
        }
        #expect(rows.isEmpty, "a taller clip asked Ghostty for rows \(rows)")
        // Forty points a row at 400 pt: the knob stays at the bottom.
        #expect(scroller.documentView?.frame.height == 4000)
        #expect(scroller.contentView.bounds.origin.y == 3600)
    }

    /// A knob drag before Ghostty answers: each move is compared with the row last asked for, not with
    /// Ghostty's offset from before the drag, so a move back to that offset still reports.
    @Test func aKnobDragReportsAMoveBackToGhosttysStaleRow() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(80))
        for y: CGFloat in [400, 900, 800, 300] { scroller.contentView.scroll(to: NSPoint(x: 0, y: y)) }
        #expect(rows == [40, 90, 80, 30])
    }

    /// A move to the row already asked for reports nothing; Ghostty's answer places the knob without a
    /// report and the next move is compared with Ghostty's row again.
    @Test func aMoveToTheRequestedRowReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(80))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 401)) // still row 40
        #expect(rows == [40])
        scroller.update(Self.bar(40))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 399)) // row 40: Ghostty's
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 800))
        #expect(rows == [40, 80])
    }
}
