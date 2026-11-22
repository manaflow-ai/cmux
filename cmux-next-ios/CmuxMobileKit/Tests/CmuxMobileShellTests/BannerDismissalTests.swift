#if os(iOS)
@testable import CmuxMobileDesign
import Testing

/// A dismissed connection banner stays hidden while its state lasts; the next episode shows again.
@Suite struct BannerDismissalTests {
    @Test func theSameStateKeepsItsDismissal() {
        #expect(BannerDismissal.remembered(.offline, after: .offline) == .offline)
    }

    @Test func noBannerEndsTheDismissal() {
        #expect(BannerDismissal.remembered(.offline, after: nil) == nil)
    }

    @Test func anotherStateEndsTheDismissal() {
        #expect(BannerDismissal.remembered(.offline, after: .reconnecting(to: "Mac")) == nil)
    }

    @Test func nothingDismissedStaysThatWay() {
        #expect(BannerDismissal.remembered(nil, after: .offline) == nil)
        #expect(BannerDismissal.remembered(nil, after: nil) == nil)
    }

    /// Dismiss Offline, recover, go offline again: the second outage shows.
    @Test func aLaterEpisodeOfTheSameStateShows() {
        var dismissed: ConnectionBannerState? = .offline
        for state in [ConnectionBannerState?.some(.connected), nil, .offline] {
            dismissed = BannerDismissal.remembered(dismissed, after: state)
        }
        #expect(dismissed != .offline)
    }
}
#endif
