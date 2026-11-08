import WebKit

/// A live isolated store paired with the environment whose cookies it holds.
struct BrowserAppSessionStoreCleanupTarget {
    let store: WKWebsiteDataStore
    let environment: BrowserAppSessionEnvironment
}
