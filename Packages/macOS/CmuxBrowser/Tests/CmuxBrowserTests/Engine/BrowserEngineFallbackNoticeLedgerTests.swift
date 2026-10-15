import Testing
import CmuxBrowser

@MainActor
@Suite
struct BrowserEngineFallbackNoticeLedgerTests {
    @Test func noticesEachReasonCodeOnce() {
        let ledger = BrowserEngineFallbackNoticeLedger()
        #expect(ledger.mostRecentReason == nil)
        #expect(ledger.recordFallback(.notBundled))
        #expect(!ledger.recordFallback(.notBundled))
        #expect(ledger.recordFallback(.startFailed("first")))
        #expect(!ledger.recordFallback(.startFailed("second")))
        #expect(ledger.mostRecentReason == .startFailed("second"))
    }
}
