public import Foundation

/// One ``BrowserSitePermissionStore`` per browser profile, shared by every
/// Chromium panel of that profile, stored in the profile's Chromium store.
@MainActor
public final class BrowserSitePermissionStoreRegistry {
    private let storage: BrowserChromiumProfileStorage
    private var stores: [UUID: BrowserSitePermissionStore] = [:]

    /// Creates a registry.
    /// - Parameter storage: Where profile stores live.
    public init(storage: BrowserChromiumProfileStorage) {
        self.storage = storage
    }

    /// The store of a profile, loaded on first use.
    public func store(forProfileID profileID: UUID) -> BrowserSitePermissionStore {
        if let store = stores[profileID] { return store }
        let store = BrowserSitePermissionStore(fileURL: storage.sitePermissionsFile(forProfileID: profileID))
        stores[profileID] = store
        return store
    }

    /// Forgets a profile's answers (profile cleared or deleted).
    public func reset(profileID: UUID) {
        store(forProfileID: profileID).reset()
        stores[profileID] = nil
    }
}
