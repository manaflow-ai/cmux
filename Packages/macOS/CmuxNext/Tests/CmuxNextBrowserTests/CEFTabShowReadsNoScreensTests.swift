import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// HOT PATH AUDIT frames (tab-switch, perf-hot `CEFLayerHosting.pageShown`): a Chromium tab show reads no display
/// list. The resize wait's cap comes from every display's shortest frame interval (`CEFResizeSyncDeadline`), which
/// changes only when a display changes (`displaysChanged`, from CEFRuntime's one app-wide observer). Before, every tab
/// show on fork API >= 27 read `NSScreen.screens` again (a WindowServer-backed list and one array per show), also when
/// the page waits for nothing (deadline 0, no cap to apply).
@MainActor
@Suite(.closesItsWindows) struct CEFTabShowReadsNoScreensTests {
    final class Reads {
        var count = 0
    }

    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: Bool, reads: Reads) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, liveResizeDeadlineMs: { 50 }, dragResizeDeadlineMs: { 30 },
                                      refreshIntervals: {
                                          reads.count += 1
                                          return [1.0 / 120]
                                      })
        hosting.view = view
        return hosting
    }

    @Test(arguments: [false, true])
    func tabShowsReadNoDisplayList(hosted: Bool) {
        let reads = Reads()
        let hosting = makeHosting(enabled: hosted, reads: reads)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        let afterCreate = reads.count
        for _ in 0..<10 { hosting.pageShown(browser: 4) }
        #expect(reads.count - afterCreate == 0, "10 tab shows read the display list \(reads.count - afterCreate) times (hosted: \(hosted))")
        // The cap still applies: a hosted page waits at most half a 120 Hz frame.
        if hosted { #expect(fake.syncs.last?.timeoutMs == 4) }
    }

    @Test func aDisplayChangeReadsTheListAgain() {
        let reads = Reads()
        let hosting = makeHosting(enabled: true, reads: reads)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.pageShown(browser: 4)
        let before = reads.count
        hosting.displaysChanged()
        #expect(reads.count == before + 1, "a display change must read the displays again")
    }
}
