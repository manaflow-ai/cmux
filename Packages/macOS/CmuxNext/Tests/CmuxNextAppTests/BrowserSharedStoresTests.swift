@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Testing

/// Both engines and the App ask one set of incognito profiles (`BrowserSharedStores`): a second
/// set would answer "not off the record" for an incognito profile, and its data would go to disk.
@MainActor struct BrowserSharedStoresTests {
    @Test func anIncognitoProfileBegunOnTheAppsStoresIsOffTheRecordInBothEngines() {
        let stores = BrowserSharedStores.inMemory()
        let cache = TabContentCache(daemon: DaemonService(),
                                    cef: CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput())
        let profile = stores.offTheRecord.begin()

        #expect(cache.webKit.profileStore.isOffTheRecord(profile))
        #expect(cache.cef.stores.offTheRecord.isOffTheRecord(profile))
        #expect(cache.browserTabs.offTheRecord.isOffTheRecord(profile))
        // One site-permission registry and one zoom table: a decision in one engine applies in both.
        #expect(cache.webKit.siteSettings === cache.cef.stores.siteSettings)
        #expect(cache.webKit.stores.siteZoom === cache.cef.stores.siteZoom)

        stores.offTheRecord.end(profile)
        #expect(cache.webKit.profileStore.isOffTheRecord(profile), "an ended profile never gets a persistent store")
    }
}
