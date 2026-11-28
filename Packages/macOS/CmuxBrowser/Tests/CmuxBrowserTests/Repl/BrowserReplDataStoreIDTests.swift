import Testing
import WebKit

@testable import CmuxBrowser

/// `tabs.open({ dataStore })` opens a tab in the store a listed id names.
/// An id must never name a later store after its own is freed, or a
/// session holding an old id would open a tab in another profile's
/// cookies and storage.
@MainActor
@Suite("Browser REPL data store ids")
struct BrowserReplDataStoreIDTests {
    @Test func aStoreKeepsItsIDAndOtherStoresHaveTheirOwn() {
        let store = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        #expect(store.browserReplID == store.browserReplID)
        #expect(store.browserReplID != other.browserReplID)
        #expect(store.browserReplID != WKWebsiteDataStore.default().browserReplID)
    }

    /// WebKit frees a store a moment after its last reference goes, and a
    /// later store often takes the same address.
    @Test func aFreedStoresIDIsNotReused() async throws {
        var seen = Set<String>()
        let count = 20
        for _ in 0..<count {
            weak var freed: WKWebsiteDataStore?
            let id = autoreleasepool {
                let store = WKWebsiteDataStore.nonPersistent()
                freed = store
                return store.browserReplID
            }
            seen.insert(id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while freed != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(freed == nil, "WebKit kept a store alive; the test cannot check id reuse")
        }
        #expect(seen.count == count, "\(count - seen.count) freed stores' ids were given to later stores")
    }
}
