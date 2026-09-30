import Testing
@testable import CmuxNextBrowser

/// A browser Chromium creates and closes before cmux adopts it (an
/// extension's chrome.tabs.create then chrome.tabs.remove under load) must
/// never be adopted: its tab would be a ghost with no page.
@Suite struct AdoptionLedgerTests {
    @Test func aClosedWaitingBrowserLeavesTheQueue() {
        var ledger = CEFAdoptionLedger()
        ledger.wait(Orphan(browser: 5, window: 1))
        ledger.wait(Orphan(browser: 6, window: 1))
        ledger.closedUnregistered(5)
        #expect(ledger.takeWaiting() == [Orphan(browser: 6, window: 1)])
        #expect(ledger.isClosed(5))
    }

    @Test func aBrowserThatClosedFirstIsNeverQueued() {
        var ledger = CEFAdoptionLedger()
        ledger.closedUnregistered(9)
        ledger.wait(Orphan(browser: 9, window: 2))
        #expect(ledger.takeWaiting().isEmpty)
        #expect(!ledger.isClosed(10))
    }
}
