import Foundation
import Testing
import CmuxBrowser

@Suite("Browser page reclaim probe bookkeeping")
struct BrowserPageReclaimProbeTests {
    @Test("A running probe or a recent busy answer holds further probes back")
    func backoff() {
        let now = Date(timeIntervalSince1970: 1_000)
        var probe = BrowserPageReclaimProbe()
        #expect(probe.allowsProbe(now: now))
        probe.isRunning = true
        #expect(!probe.allowsProbe(now: now))
        probe.isRunning = false
        probe.busyUntil = now.addingTimeInterval(BrowserPageReclaimProbe.busyBackoff)
        #expect(!probe.allowsProbe(now: now.addingTimeInterval(59)))
        #expect(probe.allowsProbe(now: now.addingTimeInterval(60)))
    }
}
