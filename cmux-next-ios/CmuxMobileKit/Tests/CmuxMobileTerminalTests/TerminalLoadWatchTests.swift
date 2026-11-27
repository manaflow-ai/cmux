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
            == .stalled(title: "Still connecting to Studio", detail: "Trying again."))
        #expect(TerminalLoadWatch.stage(.reattaching(mac: nil), waited: .seconds(60))
            == .stalled(title: "Still connecting to your Mac", detail: "Trying again."))
    }

    @Test func aGivenUpOrOfflineSessionSaysSoAtOnce() {
        guard case .stalled(let failed, _) = TerminalLoadWatch.stage(.failed(message: "x"), waited: .zero) else {
            Issue.record("a failed attach drew the skeleton"); return
        }
        #expect(failed == "Can't reach this terminal")
        guard case .stalled(let offline, _) = TerminalLoadWatch.stage(.offline(mac: "Studio"), waited: .zero) else {
            Issue.record("an offline Mac drew the skeleton"); return
        }
        #expect(offline == "Studio is offline")
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
        // The stalled stage turns the skeleton off (`showsPlaceholder: false`).
        #expect(TerminalConnectingView.content(hasLastFrame: false, showsPlaceholder: false) == .nothing)
    }
}
#endif
