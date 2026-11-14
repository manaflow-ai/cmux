import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo 2026-11-14: "I want us to also look at if we can decrease battery drain/ram on iOS app".
/// A workspace grid left on screen with 8 terminal tabs and nothing changing on the Mac read
/// every card's screen from the Mac (`read-screen`) once a second, and kept doing it while the
/// app was in the background (the grid's view still counts as visible). Each `.screenText`
/// action is one `read-screen` RPC (`GhosttyTerminalTabContent.refreshLiveCards`).
@Suite struct GridIdlePollingTests {
    typealias Tab = TerminalCardLiveRefresh.Tab

    /// 6 tabs not opened in this launch and 2 warm tabs whose pages are off screen: every one
    /// reads the Mac's screen for its card.
    static let tabs = (1...6).map { Tab(id: "cold\($0)", pageStarted: false, capturable: false, behind: false) }
        + (1...2).map { Tab(id: "warm\($0)", pageStarted: true, capturable: false, behind: false) }

    /// The `read-screen` RPCs the grid asks for over one simulated minute of 250 ms ticks.
    static func screenReadsPerMinute(_ refresh: inout TerminalCardLiveRefresh, from start: Double) -> Int {
        var reads = 0
        var now = start
        for _ in 0..<Int(60 / TerminalCardLiveRefresh.tickSeconds) {
            now += TerminalCardLiveRefresh.tickSeconds
            reads += refresh.due(tabs, now: now).count
        }
        return reads
    }

    @Test func anIdleGridReadsNoScreensFromTheMac() {
        var refresh = TerminalCardLiveRefresh()
        refresh.setVisible(true, now: 0)
        let reads = Self.screenReadsPerMinute(&refresh, from: 0)
        print("grid-idle-rpcs: 8 terminal tabs idle on screen: \(reads) read-screen RPC/min")
        #expect(reads == 0)
    }

    @Test func aBackgroundedGridReadsNoScreensFromTheMac() {
        var refresh = TerminalCardLiveRefresh()
        refresh.setVisible(true, now: 0)
        refresh.setAppActive(false, now: 0)
        let reads = Self.screenReadsPerMinute(&refresh, from: 0)
        print("grid-idle-rpcs: 8 terminal tabs, app in background: \(reads) read-screen RPC/min")
        #expect(reads == 0)
    }

    @Test func theGridTicksOnlyAfterTheMacsOutput() {
        var refresh = TerminalCardLiveRefresh()
        refresh.setVisible(true, now: 0)
        #expect(!refresh.wantsTicks(now: 0))
        refresh.macOutput("cold1", now: 10)
        #expect(refresh.wantsTicks(now: 10))
        #expect(refresh.due(Self.tabs, now: 10.25) == [.screenText("cold1")])
        // Quiet for `quietAfter`: the tick stops.
        #expect(!refresh.wantsTicks(now: 10 + TerminalCardLiveRefresh.quietAfter))
    }

    @Test func outputInTheBackgroundIsReadOnReturn() {
        var refresh = TerminalCardLiveRefresh()
        refresh.setVisible(true, now: 0)
        refresh.setAppActive(false, now: 0)
        refresh.macOutput("cold2", now: 5)
        #expect(!refresh.wantsTicks(now: 5))
        #expect(refresh.due(Self.tabs, now: 5.25) == [])
        refresh.setAppActive(true, now: 100)
        #expect(refresh.wantsTicks(now: 100))
        #expect(refresh.due(Self.tabs, now: 100.25) == [.screenText("cold2")])
    }
}
