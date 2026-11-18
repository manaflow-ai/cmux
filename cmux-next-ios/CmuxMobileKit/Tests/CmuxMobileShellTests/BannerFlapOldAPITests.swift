#if os(iOS)
@testable import CmuxMobileDesign
import Testing

/// Detector only (old API): a dismissed "Reconnecting" must stay hidden through a flap.
@Suite struct BannerFlapOldAPITests {
    @Test func flapsAfterADismissalShowNoBanner() {
        let reconnecting = ConnectionBannerState.reconnecting(to: "Mac", identity: "m1")
        var dismissed: ConnectionBannerState? = reconnecting
        var shown = 0
        for _ in 0..<10 {
            dismissed = BannerDismissal.remembered(dismissed, after: nil)
            dismissed = BannerDismissal.remembered(dismissed, after: reconnecting)
            if dismissed != reconnecting { shown += 1 }
        }
        #expect(shown == 0)
    }

    @Test func offlineOffersNoRetry() {
        #expect(!ConnectionBannerState.offline.offersRetry)
    }
}
#endif
