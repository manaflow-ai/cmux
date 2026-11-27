#if os(iOS)
import Testing
@testable import CmuxMobileTerminal

/// A terminal page never draws the skeleton's gray bars for good (Aziz's TestFlight build,
/// 2026-11-25: a terminal whose rows never came stayed on the skeleton). Past the bound, or at
/// once when the session gave up or the Mac is offline, the page says so in words with Retry,
/// and it retries the attach by itself on a bounded backoff.
@MainActor @Suite struct TerminalLoadWatchTests {
    @Test func theSkeletonShowsOnlyUpToTheBound() {
        #expect(TerminalLoadWatch.stage(.connecting(mac: "Studio"), waited: .zero) == .loading)
        #expect(TerminalLoadWatch.stage(.connecting(mac: "Studio"), waited: .seconds(7)) == .loading)
        #expect(TerminalLoadWatch.stage(.connecting(mac: "Studio"), waited: TerminalLoadWatch.bound)
            == .stalled)
        #expect(TerminalLoadWatch.stage(.reattaching(mac: nil), waited: .seconds(60))
            == .stalled)
        let macNames: [String?] = [nil, "", "Studio"]
        for mac in macNames {
            #expect(TerminalLoadStalledPanel.notice(.connecting(mac: mac)) == nil)
            #expect(TerminalLoadStalledPanel.notice(.reattaching(mac: mac)) == nil)
        }
    }

    @Test func aGivenUpOrOfflineSessionSaysSoAtOnce() {
        #expect(TerminalLoadWatch.stage(.failed(message: "x"), waited: .zero) == .stalled)
        #expect(TerminalLoadStalledPanel.notice(.failed(message: "x"))?.title == "Can't reach this terminal")
        #expect(TerminalLoadWatch.stage(.offline(mac: "Studio"), waited: .zero) == .stalled)
        #expect(TerminalLoadStalledPanel.notice(.offline(mac: "Studio"))?.title == "Studio is offline")
    }

    @Test func anAttachedPageHasNoCoverWords() {
        #expect(TerminalLoadWatch.stage(.attached, waited: .seconds(600)) == .loading)
    }

    @Test func theOwnRetriesBackOffAndKeepGoing() {
        #expect(TerminalLoadWatch.retryDelay(0) == .seconds(8))
        #expect(TerminalLoadWatch.retryDelay(1) == .seconds(15))
        #expect(TerminalLoadWatch.retryDelay(3) == .seconds(60))
        #expect(TerminalLoadWatch.retryDelay(50) == .seconds(60))
    }

    @Test func pastTheBoundTheCoverDrawsNoGrayBars() {
        // The stalled stage draws nothing under its panel (`showsPlaceholder: false`).
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: false) == .nothing)
    }
}
#endif
