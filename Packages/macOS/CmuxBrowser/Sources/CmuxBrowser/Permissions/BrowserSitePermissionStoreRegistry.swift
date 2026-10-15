public import Foundation

/// One ``BrowserSitePermissionStore`` per browser profile, shared by every
/// Chromium panel of that profile, stored in the profile's Chromium store.
@MainActor
public final class BrowserSitePermissionStoreRegistry {
    private let storage: BrowserChromiumProfileStorage
    private var stores: [UUID: BrowserSitePermissionStore] = [:]
    private var deleted: Set<UUID> = []

    /// Creates a registry.
    /// - Parameter storage: Where profile stores live.
    public init(storage: BrowserChromiumProfileStorage) {
        self.storage = storage
    }

    /// The store of a profile, loaded on first use. A deleted profile's store
    /// lives in memory only.
    public func store(forProfileID profileID: UUID) -> BrowserSitePermissionStore {
        if let store = stores[profileID] { return store }
        let store = BrowserSitePermissionStore(
            fileURL: deleted.contains(profileID) ? nil : storage.sitePermissionsFile(forProfileID: profileID)
        )
        stores[profileID] = store
        return store
    }

    /// Forgets a profile's answers (profile cleared). The same store instance
    /// stays in use, so panels holding it see the reset.
    /// - Returns: The answers forgotten.
    @discardableResult
    public func reset(profileID: UUID) -> [BrowserSitePermissionStore.Entry] {
        store(forProfileID: profileID).reset()
    }

    /// The profile was deleted: its answers are forgotten and its store never
    /// writes again (that would recreate the deleted profile's directory).
    public func retire(profileID: UUID) {
        let store = store(forProfileID: profileID)
        store.reset()
        store.retire()
        deleted.insert(profileID)
    }
}
