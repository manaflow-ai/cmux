@testable import CmuxNextPages
import Testing
import WebKit

/// The overlay pages' one data store (PageOverlayProcess): made on first use, not with the object (the app makes
/// the object while it builds its first window), and the same store for every overlay page after that, which is
/// what lets them share one web content process.
@MainActor
struct PageOverlayProcessStoreTests {
    @Test func everyOverlayPageGetsTheSameNonPersistentStore() {
        let overlay = PageOverlayProcess()
        let first = PageWebView.hostConfiguration(handler: PageSchemeHandler(resolve: { _ in nil }, devServer: nil), documentAttributes: [:],
                                                  options: PageEngineOptions(), overlayProcess: overlay).configuration
        let second = PageWebView.hostConfiguration(handler: PageSchemeHandler(resolve: { _ in nil }, devServer: nil), documentAttributes: [:],
                                                   options: PageEngineOptions(), overlayProcess: overlay).configuration
        #expect(first.websiteDataStore === second.websiteDataStore)
        #expect(first.websiteDataStore === overlay.dataStore)
        #expect(!overlay.dataStore.isPersistent)
    }
}
