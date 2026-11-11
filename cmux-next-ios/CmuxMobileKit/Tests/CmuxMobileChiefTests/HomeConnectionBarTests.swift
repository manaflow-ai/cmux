import Testing
@testable import CmuxMobileChief

/// CMUX-489: Home says at its top when its Mac is not connected and that the list is kept.
@Suite struct HomeConnectionBarTests {
    @Test func aLiveListHasNoBar() {
        #expect(HomeConnectionBar.make(offline: false, problem: nil, retrying: false, hasRows: true, macName: "Studio") == nil)
    }

    @Test func anOfflineMacNamesTheMacAndMarksTheRowsAsKept() throws {
        let bar = try #require(HomeConnectionBar.make(offline: true, problem: nil, retrying: false, hasRows: true, macName: "Studio"))
        #expect(bar.kind == .offline)
        #expect(bar.title == "Not connected to Studio")
        #expect(bar.detail.contains("last list"))
    }

    @Test func offlineWinsOverAFailedRead() throws {
        let bar = try #require(HomeConnectionBar.make(offline: true, problem: "Timed out.", retrying: false, hasRows: true, macName: nil))
        #expect(bar.kind == .offline)
        #expect(bar.title == "Not connected to your Mac")
    }

    @Test func aFailedReadOnALiveLinkSaysWhy() throws {
        let bar = try #require(HomeConnectionBar.make(offline: false, problem: "Timed out.", retrying: false, hasRows: false, macName: "Studio"))
        #expect(bar.kind == .failed)
        #expect(bar.title == "Couldn't load Home from Studio")
        #expect(bar.detail.hasPrefix("Timed out."))
        #expect(!bar.detail.contains("last list"))
    }

    @Test func theBarStaysWhileTryAgainRuns() throws {
        // Reconnecting clears the offline state before the read answers: the bar stays, spinning.
        let bar = try #require(HomeConnectionBar.make(offline: false, problem: nil, retrying: true, hasRows: true, macName: "Studio"))
        #expect(bar.kind == .retrying)
        #expect(bar.title == "Reconnecting to Studio…")
    }

    @Test func aRetryOfAFailedReadSaysItLoadsNotReconnects() throws {
        let bar = try #require(HomeConnectionBar.make(offline: false, problem: "Timed out.", retrying: true, reconnecting: false,
                                                      hasRows: true, macName: "Studio"))
        #expect(bar.title == "Loading Home from Studio…")
    }
}
