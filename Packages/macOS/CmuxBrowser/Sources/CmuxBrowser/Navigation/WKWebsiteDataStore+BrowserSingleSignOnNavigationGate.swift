public import WebKit

/// The key of the gate each store carries (its address is the key).
nonisolated(unsafe) private var singleSignOnNavigationGateKey: UInt8 = 0

extension WKWebsiteDataStore {
    /// The gate for main-frame navigations of the web views that use this store.
    ///
    /// WebKit keeps its one Extensible SSO authorization on the website data
    /// store, so the gate lives there too: web views that share a store take
    /// turns, and web views on different stores do not wait for each other.
    /// Created on first use and kept for the life of the store.
    @MainActor
    public var singleSignOnNavigationGate: BrowserSingleSignOnNavigationGate {
        if let gate = objc_getAssociatedObject(self, &singleSignOnNavigationGateKey)
            as? BrowserSingleSignOnNavigationGate {
            return gate
        }
        let gate = BrowserSingleSignOnNavigationGate()
        objc_setAssociatedObject(self, &singleSignOnNavigationGateKey, gate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return gate
    }
}
