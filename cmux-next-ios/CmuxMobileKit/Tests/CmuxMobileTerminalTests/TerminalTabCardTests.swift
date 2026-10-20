import Foundation
import Testing
@testable import CmuxMobileTerminal

/// D5 / T-TABS-02: a tab never opened in this launch showed "Connecting to
/// <Mac>…" with a spinner in the grid forever (its session starts only when
/// its page is built). Its card shows its saved frame or the static placeholder instead.
@Suite struct TerminalTabCardTests {
    @Test func aNeverOpenedTabShowsNoSpinner() {
        #expect(!TerminalConnectionState.connecting(mac: "Mac").cardShowsConnecting(sessionStarted: false))
    }

    @Test func anOpenedTabStillShowsItsConnectionState() {
        #expect(TerminalConnectionState.connecting(mac: "Mac").cardShowsConnecting(sessionStarted: true))
        #expect(TerminalConnectionState.reattaching(mac: nil).cardShowsConnecting(sessionStarted: true))
        #expect(!TerminalConnectionState.attached.cardShowsConnecting(sessionStarted: true))
    }
}

/// Verifier D5 (round 3, T-TABS-02): a tab not opened in this launch showed a
/// black card with only a cursor for minutes with the link up: its saved
/// frame from an earlier launch was a blank screen. Its card shows the Mac's
/// screen as text (`read-screen`) once fetched; a live page's own snapshot
/// still wins once the tab was opened.
@Suite struct TerminalCardContentTests {
    @Test func aNeverOpenedTabShowsTheMacsScreenOverASavedFrame() {
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: true,
                                           screenText: "$ ls\nREADME.md") == .screenText)
    }

    @Test func anOpenedTabShowsItsLiveSnapshot() {
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: false, hasSnapshot: true,
                                           screenText: "$ ls") == .snapshot)
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: true, hasSnapshot: true,
                                           screenText: nil) == .connecting)
    }

    @Test func blankScreenTextIsNotContent() {
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: true,
                                           screenText: "\n  \n") == .savedFrame)
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: false,
                                           screenText: nil) == .placeholder)
    }
}

/// VERIFY-round8 Claim 8 / T-TABS-01: at the first grid open after a launch an
/// inactive card showed a saved frame from an earlier session (old Codex
/// output) as current while the Mac had moved on. A saved frame of a tab not
/// opened in this launch is only a stand-in until the Mac's screen arrives,
/// and the grid's opening asks the Mac again.
@Suite struct TerminalCardStaleFrameTests {
    @Test func aSavedFrameIsNotShownAsCurrent() {
        // The Mac has not answered yet: the saved frame is marked as not current.
        #expect(TerminalCardContent.choose(sessionStarted: false, connecting: false, hasSnapshot: true,
                                           screenText: nil) == .savedFrame)
        #expect(TerminalCardContent.savedFrame.isCurrent == false)
        #expect(TerminalCardContent.snapshot.isCurrent && TerminalCardContent.screenText.isCurrent)
    }

    @Test func theGridOpeningAsksTheMacAgain() {
        var refresh = TerminalCardScreenRefresh()
        let t0 = Date(timeIntervalSince1970: 1000)
        let asked1 = refresh.begin("s1", now: t0) != nil
        #expect(asked1)
        // A card rebuilt within 3 s does not ask again ...
        let asked2 = refresh.begin("s1", now: t0.addingTimeInterval(1)) != nil
        #expect(!asked2)
        // ... but the grid opening does.
        let asked3 = refresh.begin("s1", now: t0.addingTimeInterval(1), gridOpening: true) != nil
        #expect(asked3)
    }

    @Test func aFailedReadIsAskedAgainAtTheNextBuild() {
        var refresh = TerminalCardScreenRefresh()
        let t0 = Date(timeIntervalSince1970: 1000)
        let asked4 = refresh.begin("s1", now: t0) != nil
        #expect(asked4)
        // The link was not up yet: no answer. The next card build asks again
        // instead of keeping the saved frame for the throttle's sake.
        refresh.failed("s1", request: 1)
        let asked5 = refresh.begin("s1", now: t0.addingTimeInterval(0.5)) != nil
        #expect(asked5)
    }
}

/// Round 11 A6: card reads are ordered: a slower old reply never replaces
/// a newer card text, and an old failure never clears a newer read's time.
@Suite struct TerminalCardScreenRefreshOrderTests {
    @Test func anOlderReplyAfterANewerOneIsDropped() throws {
        var refresh = TerminalCardScreenRefresh()
        let t0 = Date(timeIntervalSince1970: 1000)
        let oldAsk = refresh.begin("s1", now: t0)
        let old = try #require(oldAsk)
        let newAsk = refresh.begin("s1", now: t0.addingTimeInterval(1), gridOpening: true)
        let new = try #require(newAsk)
        let newKept = refresh.finished("s1", request: new)
        let oldKept = refresh.finished("s1", request: old)
        #expect(newKept)
        #expect(!oldKept)
    }

    @Test func aCardBuildWhileAReadIsOutAsksNothing() {
        var refresh = TerminalCardScreenRefresh()
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = refresh.begin("s1", now: t0)
        #expect(first != nil)
        // 4 s later the first read has not answered: no second one.
        let second = refresh.begin("s1", now: t0.addingTimeInterval(4))
        #expect(second == nil)
    }

    @Test func anOldFailureKeepsTheNewerReadsTime() throws {
        var refresh = TerminalCardScreenRefresh()
        let t0 = Date(timeIntervalSince1970: 1000)
        let oldAsk = refresh.begin("s1", now: t0)
        let old = try #require(oldAsk)
        let newAsk = refresh.begin("s1", now: t0.addingTimeInterval(1), gridOpening: true)
        let new = try #require(newAsk)
        refresh.failed("s1", request: old)
        let newKept = refresh.finished("s1", request: new)
        #expect(newKept)
        let again = refresh.begin("s1", now: t0.addingTimeInterval(2))
        #expect(again == nil)
    }
}

/// VERIFY-round5 V5-6 / T-TABS-01: a grid card shows the top of the page
/// (TabsKit lays a page-sized card out top-aligned in a 177 x 249.3 card),
/// so the newest rows and the agent's prompt were cut off. The snapshot is
/// placed so its bottom is the card's bottom edge.
@Suite struct TerminalCardCropTests {
    @Test func theCardShowsTheBottomOfThePage() {
        let crop = TerminalCardCrop(width: 402, imageHeight: 874)
        #expect(abs(crop.visibleHeight - 402 * 249.3 / 177) < 0.01)
        // The image moves up by what the card cannot show.
        #expect(abs(crop.imageTop - (crop.visibleHeight - 874)) < 0.01)
        // A short image is not moved.
        #expect(TerminalCardCrop(width: 402, imageHeight: 300).imageTop == 0)
    }

    /// V5-6 (round 7): the band under the composer is the page's toolbar
    /// inset, blank in a snapshot; the card ends at the composer instead.
    @Test func theCardEndsAtTheComposerNotTheToolbarBand() {
        let crop = TerminalCardCrop(width: 402, imageHeight: 874, bottomTrim: 82)
        #expect(abs(crop.imageTop - (crop.visibleHeight - (874 - 82))) < 0.01)
        // Never past the image's top.
        #expect(TerminalCardCrop(width: 402, imageHeight: 500, bottomTrim: 82).imageTop == 0)
    }
}

/// D11: a kill without backgrounding relaunched to no saved frame. The save
/// on output ran in the same turn as the first output batch, before Ghostty
/// presented it, so a tab whose replay was its only output saved the frame
/// from before the replay. Every save now waits for the frame (0.5 s) and
/// saves at most every 3 s.
@Suite struct TerminalFrameSaveScheduleTests {
    /// Round 8: a 370 ms render every 3 s while output streamed.
    @Test func noSaveWhileOutputStreamsUntilTheMaxWait() {
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.02, sinceRequested: 3) != nil)
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.6, sinceRequested: 3) == nil)
        #expect(TerminalFrameSaveSchedule.remainingWait(sinceLastOutput: 0.02, sinceRequested: 15) == nil)
    }

    @Test func theFirstSaveWaitsForTheFrameToBePresented() {
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: .infinity) == 0.5)
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: 10) == 0.5)
        #expect(TerminalFrameSaveSchedule.delay(sinceLastSave: 1) == 2)
    }
}
