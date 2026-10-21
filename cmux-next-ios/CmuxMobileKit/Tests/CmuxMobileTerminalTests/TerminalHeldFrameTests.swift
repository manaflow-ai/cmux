import Foundation
import Testing
@testable import CmuxMobileTerminal

/// design/terminal R3-2 / round 5: hold the last frame until a TUI repaints.
@Suite struct TerminalHeldFrameTests {
    let rule = TerminalHeldFrame()

    @Test func anEmptyTUIScreenKeepsTheFrame() {
        #expect(!rule.shouldRelease(isAlternate: true, nonBlankRows: 0, rows: 24, elapsed: 0.6))
        // A header line alone is not a repaint yet.
        #expect(!rule.shouldRelease(isAlternate: true, nonBlankRows: 2, rows: 24, elapsed: 0.9))
    }

    @Test func aRepaintedTUIReleasesIt() {
        #expect(rule.shouldRelease(isAlternate: true, nonBlankRows: 8, rows: 24, elapsed: 1.0))
    }

    @Test func theCapLongerThanTopsTickStillEndsIt() {
        #expect(TerminalHeldFrame.cap > 1.0)
        #expect(rule.shouldRelease(isAlternate: true, nonBlankRows: 0, rows: 24, elapsed: 1.5))
    }

    @Test func aShellReplayReleasesOnAnyText() {
        #expect(rule.shouldRelease(isAlternate: false, nonBlankRows: 1, rows: 41, elapsed: 0.05))
        #expect(!rule.shouldRelease(isAlternate: false, nonBlankRows: 0, rows: 41, elapsed: 0.05))
    }

    @Test func countsRowsWithText() {
        #expect(TerminalHeldFrame.nonBlankRows(in: "Processes: 1\n\n   \nPID COMMAND\n", limit: 24) == 2)
        #expect(TerminalHeldFrame.nonBlankRows(in: "a\nb\nc", limit: 2) == 2)
    }
}

/// qa11 wt-read2-a (W-T, two hostd kills, reading ~1900 rows up while a GEN
/// loop streams): one source frame fully black at a reattach. The held frame
/// went on the first present after the reading mark was restored, before
/// that frame was known to cover the restored rows: Ghostty's first frame
/// after the replay showed the end (rendered before the request for the
/// reader's rows), was placed there, and the page at the reader's rows had
/// nothing under it. The held frame now goes only once a placed frame covers
/// the rows the page shows (a TUI's screen has no scroll: drawn is enough).
@Suite struct TerminalHeldFrameReleaseTests {
    @Test func aFrameOfTheEndDoesNotReleaseItOverTheReadersRows() {
        // Restored to rows 14927..<14969; the first frame placed at 16834 (the end).
        let cover = TerminalFrameCover(presentedTop: 16834, surfaceRows: 151)
        #expect(!TerminalHeldFrame.releasesOnPresent(isAlternate: false, replayDrawn: true, markPending: false,
                                                     cover: cover, visibleTop: 14927, visibleBottom: 14969,
                                                     documentRows: 0..<16985))
        // The frame for the reader's rows.
        #expect(TerminalHeldFrame.releasesOnPresent(isAlternate: false, replayDrawn: true, markPending: false,
                                                    cover: TerminalFrameCover(presentedTop: 14880, surfaceRows: 151),
                                                    visibleTop: 14927, visibleBottom: 14969, documentRows: 0..<16985))
    }

    @Test func aPendingMarkOrAnUndrawnReplayKeepsIt() {
        let cover = TerminalFrameCover(presentedTop: 14880, surfaceRows: 151)
        #expect(!TerminalHeldFrame.releasesOnPresent(isAlternate: false, replayDrawn: true, markPending: true,
                                                     cover: cover, visibleTop: 14927, visibleBottom: 14969, documentRows: 0..<16985))
        #expect(!TerminalHeldFrame.releasesOnPresent(isAlternate: false, replayDrawn: false, markPending: false,
                                                     cover: cover, visibleTop: 14927, visibleBottom: 14969, documentRows: 0..<16985))
        // A TUI's screen: drawn is enough.
        #expect(TerminalHeldFrame.releasesOnPresent(isAlternate: true, replayDrawn: true, markPending: false,
                                                    cover: TerminalFrameCover(presentedTop: 0, surfaceRows: 151),
                                                    visibleTop: 14927, visibleBottom: 14969, documentRows: 0..<16985))
    }
}
