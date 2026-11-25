import CmuxBrowser
import Testing
import WebKit

// WebKit keeps its Extensible SSO authorization per website data store, so web
// views take turns only with the others on their own store (#53548).
@MainActor
@Suite
struct BrowserSingleSignOnNavigationGateStoreTests {
    @Test func storeKeepsItsGateAndOtherStoresHaveTheirOwn() {
        let store = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()

        #expect(store.singleSignOnNavigationGate === store.singleSignOnNavigationGate)
        #expect(store.singleSignOnNavigationGate !== other.singleSignOnNavigationGate)
        #expect(store.singleSignOnNavigationGate !== WKWebsiteDataStore.default().singleSignOnNavigationGate)
    }
}
