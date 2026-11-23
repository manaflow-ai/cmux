import Testing
@testable import CmuxMobileBrowserStream

/// A tapped browser tab that is not live yet shows the picture the phone holds;
/// a live, waiting or unavailable page never has an old picture drawn over it.
@Suite struct LastKnownPictureTests {
    @Test @MainActor func onlyAConnectingPageWithAPictureShowsIt() {
        #expect(StreamedBrowserPage.showsLastKnown(phase: .connecting, hasLastKnown: true))
        #expect(!StreamedBrowserPage.showsLastKnown(phase: .connecting, hasLastKnown: false))
        #expect(!StreamedBrowserPage.showsLastKnown(phase: .live, hasLastKnown: true))
        #expect(!StreamedBrowserPage.showsLastKnown(phase: .waiting("Reconnecting browser…"), hasLastKnown: true))
        #expect(!StreamedBrowserPage.showsLastKnown(phase: .unavailable, hasLastKnown: true))
    }
}
