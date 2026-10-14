import Testing
@testable import CmuxBrowser

@MainActor
@Suite struct BrowserReplDownloadLedgerTests {
    @Test func finishedBeforeWaitingReturnsAtOnce() async {
        let ledger = BrowserReplDownloadLedger()
        ledger.finish(id: "d1", path: "/tmp/a.txt", error: nil)
        #expect(await ledger.wait(for: "d1") == .init(path: "/tmp/a.txt", error: nil))
    }

    @Test func finishWhileWaitingWakesTheWaiter() async {
        let ledger = BrowserReplDownloadLedger()
        let waiting = Task { await ledger.wait(for: "d2") }
        await Task.yield()
        ledger.finish(id: "d2", path: "/tmp/b.txt", error: nil)
        #expect(await waiting.value == .init(path: "/tmp/b.txt", error: nil))
    }

    /// The race behind `download.path()` hanging in full real-app runs: the
    /// completion arrives after the lookup missed and before the waiter is
    /// registered. It must not be lost.
    @Test func finishBetweenLookupAndRegistrationIsNotLost() async {
        let ledger = BrowserReplDownloadLedger()
        ledger.willWait = { id in ledger.finish(id: id, path: "/tmp/c.txt", error: nil) }
        let waiting = Task { await ledger.wait(for: "d3") }
        // Give the waiter a bounded chance, then release it so a lost
        // completion fails the test instead of hanging it.
        for _ in 0..<1000 { await Task.yield() }
        ledger.releaseWaiters()
        #expect(await waiting.value == .init(path: "/tmp/c.txt", error: nil))
    }

    @Test func releasingWaitersGivesUp() async {
        let ledger = BrowserReplDownloadLedger()
        let waiting = Task { await ledger.wait(for: "d4") }
        await Task.yield()
        ledger.releaseWaiters()
        #expect(await waiting.value == nil)
    }
}
