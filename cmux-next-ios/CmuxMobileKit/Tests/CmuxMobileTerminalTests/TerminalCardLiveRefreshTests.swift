import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Full verify 2026-10-19 D6 (T-TABS-01, T-REG-1350-a): while the grid was
/// open the active card stayed at row 78 while the Mac went from 143 to 201.
/// The card was a snapshot taken once, when the grid opened. While the grid
/// is visible (and not scrolling) each card is refreshed, throttled, so it
/// is never more than about a second behind the page.
@Suite struct TerminalCardLiveRefreshTests {
    typealias Tab = TerminalCardLiveRefresh.Tab

    private func visible() -> TerminalCardLiveRefresh {
        var refresh = TerminalCardLiveRefresh()
        refresh.setVisible(true, now: 0)
        return refresh
    }

    @Test func aStreamingActiveCardIsRetakenWhileTheGridShows() {
        var refresh = visible()
        let tab = Tab(id: "t1", pageStarted: true, capturable: true, behind: true)
        #expect(refresh.due([tab], now: 0.6) == [.snapshot("t1")])
        // Throttled: not again before the interval.
        #expect(refresh.due([tab], now: 0.8) == [])
        #expect(refresh.due([tab], now: 1.2) == [.snapshot("t1")])
    }

    @Test func aQuietCardIsNotRetaken() {
        var refresh = visible()
        #expect(refresh.due([Tab(id: "t1", pageStarted: true, capturable: true, behind: false)], now: 5) == [])
    }

    @Test func nothingWhileTheGridIsHiddenOrScrolling() {
        var refresh = TerminalCardLiveRefresh()
        let tab = Tab(id: "t1", pageStarted: true, capturable: true, behind: true)
        #expect(refresh.due([tab], now: 5) == [])
        refresh.setVisible(true, now: 5)
        refresh.setScrolling(true)
        #expect(refresh.due([tab], now: 6) == [])
        refresh.setScrolling(false)
        #expect(refresh.due([tab], now: 6.1) == [.snapshot("t1")])
        refresh.setVisible(false, now: 7)
        #expect(refresh.due([tab], now: 8) == [])
    }

    @Test func aPageThatCannotBeCapturedAsksTheMacForItsScreen() {
        var refresh = visible()
        // A warm tab whose page is not in a window (not the active one), and
        // a tab never opened in this launch: both read the Mac's screen.
        let warm = Tab(id: "t2", pageStarted: true, capturable: false, behind: true)
        let cold = Tab(id: "t3", pageStarted: false, capturable: false, behind: false)
        #expect(refresh.due([warm, cold], now: 1.0) == [.screenText("t2"), .screenText("t3")])
        #expect(refresh.due([warm, cold], now: 1.5) == [])
        #expect(refresh.due([warm, cold], now: 2.0) == [.screenText("t2"), .screenText("t3")])
    }

    @Test func theRefreshKeepsCardsUnderASecondOld() {
        #expect(TerminalCardLiveRefresh.snapshotInterval + TerminalCardLiveRefresh.tickSeconds <= 1)
        #expect(TerminalCardLiveRefresh.screenTextInterval <= 1)
    }
}

/// A started tab whose page is off screen (a warm tab other than the active
/// one) shows the Mac's screen text once it is newer than its snapshot.
@Suite struct TerminalCardFresherTextTests {
    @Test func newerScreenTextBeatsAnOlderSnapshotOfAStartedTab() {
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: false, hasSnapshot: true,
                                           screenText: "$ seq 200\n200", screenTextIsNewer: true) == .screenText)
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: false, hasSnapshot: true,
                                           screenText: "$ seq 200\n200", screenTextIsNewer: false) == .snapshot)
        // Connecting still wins, and blank text is not content.
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: true, hasSnapshot: true,
                                           screenText: "x", screenTextIsNewer: true) == .connecting)
        #expect(TerminalCardContent.choose(sessionStarted: true, connecting: false, hasSnapshot: true,
                                           screenText: " \n", screenTextIsNewer: true) == .snapshot)
    }

    @Test func theScreenReadCanBeAskedAtTheGridsShorterInterval() {
        var refresh = TerminalCardScreenRefresh()
        let now = Date(timeIntervalSince1970: 0)
        let first = refresh.begin("t", now: now, interval: 1)
        #expect(first != nil)
        _ = refresh.finished("t", request: first!)
        #expect(refresh.begin("t", now: now.addingTimeInterval(0.5), interval: 1) == nil)
        #expect(refresh.begin("t", now: now.addingTimeInterval(1.0), interval: 1) != nil)
    }
}
