import CoreGraphics
@testable import CmuxMobileTerminal
import Testing

/// VERIFY-round6 V6-2/3/4: a black page lasting seconds, until a touch.
@Suite struct TerminalBlankWatchTests {
    @Test func coverageComparesTheVisibleRowsWithTheFrame() {
        // Following at the cap after a prune: the frame was placed at 17590,
        // the page shows rows 16815..<16854.
        #expect(!TerminalBlankWatch.covers(presentedTop: 17590, surfaceRows: 151, visibleTop: 16815, visibleBottom: 16854,
                                           documentRows: 0..<16854))
        #expect(TerminalBlankWatch.covers(presentedTop: 16703, surfaceRows: 151, visibleTop: 16815, visibleBottom: 16854,
                                          documentRows: 0..<16854))
        // Rows past the document's end are the page's own blank.
        #expect(TerminalBlankWatch.covers(presentedTop: 0, surfaceRows: 151, visibleTop: 0, visibleBottom: 400,
                                          documentRows: 0..<20))
    }

    @Test func aStretchPastTheDeadlineAsksForARecoveryAndAgainUntilCovered() {
        var watch = TerminalBlankWatch()
        do { let r = watch.observe(covered: false, now: 10.0); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.2); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.26); #expect(r) }
        #expect(watch.events == 1)
        do { let r = watch.observe(covered: false, now: 10.3); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.52); #expect(r) }
        #expect(watch.events == 1)
        do { let r = watch.observe(covered: true, now: 10.6); #expect(!r) }
        #expect(abs(watch.longest - 0.6) < 0.001)
        // A short gap (a frame in flight) is not an event.
        do { let r = watch.observe(covered: false, now: 11.0); #expect(!r) }
        do { let r = watch.observe(covered: true, now: 11.05); #expect(!r) }
        #expect(watch.events == 1)
    }
}

/// VERIFY-round8 "The blank flag": the frame log flagged 752 frames (2-3
/// frame runs, also while the keyboard showed) in a run whose video has no
/// black. The flag compared the frame with every row under the scroll view's
/// bounds: rows under the status bar, the composer and the keyboard, and a
/// partial row at either edge. It now flags only what a person sees: the
/// legible band (below the top inset, above the composer) uncovered by the
/// frame on screen for at least one row's height, inside the document.
@Suite struct TerminalBlankFlagTests {
    let cell: CGFloat = 20

    @Test func rowsUnderTheComposerOrASliverAreNotBlank() {
        // The frame covers 0..<3000 pt; the page shows 2200..<3100 pt, the
        // composer's top at 2900 (rows under it are behind the card).
        #expect(TerminalBlankWatch.uncoveredHeight(frame: 0..<3000, document: 0..<3100, legible: 2260..<2900) == 0)
        #expect(!TerminalBlankWatch.showsBlank(frame: 0..<3000, document: 0..<3100, legible: 2260..<2900, cellHeight: cell))
        // A 6 pt sliver of a row at the composer's edge.
        #expect(TerminalBlankWatch.uncoveredHeight(frame: 0..<2894, document: 0..<3100, legible: 2260..<2900) == 6)
        #expect(!TerminalBlankWatch.showsBlank(frame: 0..<2894, document: 0..<3100, legible: 2260..<2900, cellHeight: cell))
        // Under the top inset (the status bar) only.
        #expect(!TerminalBlankWatch.showsBlank(frame: 2250..<5000, document: 0..<5000, legible: 2260..<2900, cellHeight: cell))
        // Past the document's end: the page's own background.
        #expect(!TerminalBlankWatch.showsBlank(frame: 2000..<2500, document: 0..<2500, legible: 2260..<2900, cellHeight: cell))
    }

    @Test func aPageTheFrameMissesIsBlank() {
        // The jump's frame placed below the rows shown: the whole page black.
        #expect(TerminalBlankWatch.showsBlank(frame: 9000..<12000, document: 0..<12000, legible: 2260..<2900, cellHeight: cell))
        // Two rows uncovered at the bottom of the legible band.
        #expect(TerminalBlankWatch.uncoveredHeight(frame: 0..<2860, document: 0..<3100, legible: 2260..<2900) == 40)
        #expect(TerminalBlankWatch.showsBlank(frame: 0..<2860, document: 0..<3100, legible: 2260..<2900, cellHeight: cell))
    }
}
