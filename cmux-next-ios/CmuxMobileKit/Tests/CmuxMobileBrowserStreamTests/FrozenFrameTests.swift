import Testing
@testable import CmuxMobileBrowserStream

/// When a streamed browser tab's frozen frame (its grid card) stays over the
/// opening page: Safari keeps a tab's last frame while it loads, where the page
/// used to grow as a black "Loading browser session…".
@Suite struct FrozenFrameCoverTests {
    @Test func anOpeningPageWithAStillStaysUnderIt() {
        #expect(StreamedBrowserModel.coversWithSnapshot(showsPicture: false, hasSnapshot: true, phase: .connecting))
        // Welcomed (`rb.screen_applied`) but no picture decoded yet.
        #expect(StreamedBrowserModel.coversWithSnapshot(showsPicture: false, hasSnapshot: true, phase: .live))
    }

    @Test func thePagesOwnPictureReplacesTheStill() {
        #expect(!StreamedBrowserModel.coversWithSnapshot(showsPicture: true, hasSnapshot: true, phase: .live))
        #expect(!StreamedBrowserModel.coversWithSnapshot(showsPicture: true, hasSnapshot: true, phase: .connecting))
    }

    @Test func withNoStillThePageShowsItsLoadingStatus() {
        #expect(!StreamedBrowserModel.coversWithSnapshot(showsPicture: false, hasSnapshot: false, phase: .connecting))
    }

    @Test func aPageWaitingOnTheMacOrThePersonShowsItsStatus() {
        #expect(!StreamedBrowserModel.coversWithSnapshot(showsPicture: false, hasSnapshot: true, phase: .waiting("Reconnecting to the Mac…")))
        #expect(!StreamedBrowserModel.coversWithSnapshot(showsPicture: false, hasSnapshot: true, phase: .unavailable))
    }
}
