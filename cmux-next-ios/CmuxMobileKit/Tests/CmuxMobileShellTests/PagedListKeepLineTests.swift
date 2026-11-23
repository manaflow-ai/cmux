#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// Which rows that change height move the offset with them (``PagedListKeepLine``), as plain data.
/// A row whose top is above the line is corrected (the rows under it stay); below it, it pushes them.
struct PagedListKeepLineTests {
    private func line(follows: Bool, sliding: Bool, scrolling: Bool = false) -> CGFloat {
        PagedListKeepLine.line(.init(follows: follows, sliding: sliding, scrolling: scrolling, readerTop: 1000, bottomEdge: 1700))
    }

    /// The follow slide runs and a row on screen (top at 1400, between the reader's top edge and the
    /// bottom edge) changes height: corrected, so nothing under it moves beyond the slide's own step
    /// (stack3 baseline 05921b74 and full 27 843cd21e: `.up` inserts and flood `r+282, o+13, m_+118`,
    /// 118 pt; `.down` inserts `m_+54.3 x3` while the slide brings the new top rows in, 106-126 pt).
    @Test func aRowOnScreenResizingDuringTheSlideIsCorrected() {
        #expect(1400 < line(follows: true, sliding: true))
    }

    /// The slide's line stops at the bottom edge: a row below the screen pushes nothing drawn.
    @Test func aRowBelowTheScreenDuringTheSlideIsNotCorrected() {
        #expect(!(1800 < line(follows: true, sliding: true)))
    }

    /// At rest, following, no slide: the reader's top edge, as before (the layout pass keeps the
    /// newest row on the bottom edge itself, `stayOnNewest`).
    @Test func atRestTheLineIsTheReadersTopEdge() {
        #expect(line(follows: true, sliding: false) == 1000)
    }

    /// Not following (the reader is mid-list): the reader's top edge, whatever runs.
    @Test func notFollowingTheLineIsTheReadersTopEdge() {
        #expect(line(follows: false, sliding: false) == 1000)
        #expect(line(follows: false, sliding: true) == 1000)
    }

    /// A finger on the list or a fling: the reader's top edge (the slide never fights the scroll).
    @Test func whileScrollingTheLineIsTheReadersTopEdge() {
        #expect(line(follows: true, sliding: true, scrolling: true) == 1000)
    }
}
#endif
