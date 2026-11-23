#if os(iOS)
@testable import CmuxMobileDesign
import Foundation
import Testing

/// Old-code detector for cmux#46665 (not for merge): the flap rule written against the
/// pre-#46665 `BannerDismissal.remembered(_:after:)`. A dismissed "Reconnecting", the link
/// back for a moment, then down again: the banner must stay hidden. Expected red on base.
@Suite struct BannerFlapOldAPITests {
    @Test func aFlapAfterADismissalShowsNoBanner() {
        let reconnecting = ConnectionBannerState.reconnecting(to: "Mac", identity: "m1")
        var dismissed: ConnectionBannerState? = reconnecting
        dismissed = BannerDismissal.remembered(dismissed, after: nil)
        dismissed = BannerDismissal.remembered(dismissed, after: reconnecting)
        #expect(dismissed == reconnecting, "a flap right after the link came back shows the dismissed banner again")
    }
}
#endif
