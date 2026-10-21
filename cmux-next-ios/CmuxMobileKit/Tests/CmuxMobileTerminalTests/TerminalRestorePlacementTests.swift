import Testing
@testable import CmuxMobileTerminal

/// termqa N1 / A8 (VERIFY-round11 B1, wd-read1-a): after a reattach whose
/// replay crossed a history prune, the reader's rows were restored at 14805 of
/// 17184 and requested (viewport 14757), but the page was black for 250 ms:
/// "blank page: rows 14805..<14860 not in the frame at 17033 (report 14757,
/// request 14757) … placed by the report".
@Suite struct TerminalRestorePlacementTests {
    private let endFrame = (0..<151).map { UInt64(1_000 + $0) }
    private let readerFrame = (0..<151).map { UInt64(5_000 + $0) }

    /// The replay's frame of the end is on screen at 17033 (its report). The
    /// restore asks for 14757; its first frame shares no row with the end's,
    /// and Ghostty's report for the request is not in yet. The frame is the
    /// request's, not the report's: placed at 17033, every later frame of
    /// the reader's rows matched it there.
    @Test func aFrameAfterANewerRequestThatMatchesNothingIsPlacedAtTheRequest() {
        let match = TerminalPresentMatch(presentedTop: 17_033, reportedTop: 17_033, requestedTop: 14_757,
                                         recentRequests: [], activeTop: 17_033, requestIsNewer: true)
        #expect(match.match(previous: endFrame, current: readerFrame).top == 14_757)
    }

    /// With the report newer than the request, an unmatched frame stays at
    /// the report (Ghostty moved the viewport on its own, e.g. a reset).
    @Test func anUnmatchedFrameWithAnOlderRequestIsPlacedAtTheReport() {
        let match = TerminalPresentMatch(presentedTop: 17_033, reportedTop: 16_900, requestedTop: 14_757,
                                         recentRequests: [], activeTop: 17_033, requestIsNewer: false)
        #expect(match.match(previous: endFrame, current: readerFrame).top == 16_900)
    }

    /// A frame rendered before the request (the end's rows again) still
    /// matches the frame on screen and stays where it is.
    @Test func aFrameOfTheOldViewportStillMatchesInPlace() {
        let match = TerminalPresentMatch(presentedTop: 17_033, reportedTop: 17_033, requestedTop: 14_757,
                                         recentRequests: [], activeTop: 17_033, requestIsNewer: true)
        #expect(match.match(previous: endFrame, current: endFrame).top == 17_033)
    }

    /// The held frame stays past the 1.5 s cap while the frame placed does
    /// not cover the page's rows; it goes once one does, on a TUI's screen,
    /// or at the cover cap.
    @Test func theHeldFrameStaysUntilAPlacedFrameCoversThePage() {
        let rows = 0..<17_184
        let atEnd = TerminalFrameCover(presentedTop: 17_033, surfaceRows: 151)
        let atReader = TerminalFrameCover(presentedTop: 14_757, surfaceRows: 151)
        #expect(!TerminalHeldFrame.releasesAtCap(isAlternate: false, cover: atEnd, visibleTop: 14_805, visibleBottom: 14_860,
                                                 documentRows: rows, elapsed: TerminalHeldFrame.cap))
        #expect(TerminalHeldFrame.releasesAtCap(isAlternate: false, cover: atReader, visibleTop: 14_805, visibleBottom: 14_860,
                                                documentRows: rows, elapsed: TerminalHeldFrame.cap))
        #expect(TerminalHeldFrame.releasesAtCap(isAlternate: true, cover: atEnd, visibleTop: 0, visibleBottom: 0,
                                                documentRows: rows, elapsed: TerminalHeldFrame.cap))
        #expect(TerminalHeldFrame.releasesAtCap(isAlternate: false, cover: atEnd, visibleTop: 14_805, visibleBottom: 14_860,
                                                documentRows: rows, elapsed: TerminalHeldFrame.coverCap))
    }
}
