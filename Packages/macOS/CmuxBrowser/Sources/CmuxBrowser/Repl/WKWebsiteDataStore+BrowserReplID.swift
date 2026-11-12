public import WebKit

/// The key of the id each store carries (its address is the key).
nonisolated(unsafe) private var browserReplIDKey: UInt8 = 0

extension WKWebsiteDataStore {
    /// An opaque id for this store, equal for tabs that share cookies and
    /// storage (`tabs.list`, `tabs.dataStore`), for the life of the store.
    ///
    /// A random UUID the store carries, assigned on first use, so no later
    /// store ever gets it: a store's address is reused once it is freed, and
    /// a session holding an old id would otherwise open a tab
    /// (`tabs.open({ dataStore })`) in another store's cookies and storage.
    @MainActor
    public var browserReplID: String {
        if let id = objc_getAssociatedObject(self, &browserReplIDKey) as? String { return id }
        let id = UUID().uuidString.lowercased()
        objc_setAssociatedObject(self, &browserReplIDKey, id, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return id
    }
}
