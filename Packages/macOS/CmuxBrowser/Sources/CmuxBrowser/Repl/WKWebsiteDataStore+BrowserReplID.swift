public import WebKit

extension WKWebsiteDataStore {
    /// An opaque id for this store, equal for tabs that share cookies and
    /// storage (`tabs.list`, `tabs.dataStore`), for the life of the store.
    @MainActor
    public var browserReplID: String {
        String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16)
    }
}
