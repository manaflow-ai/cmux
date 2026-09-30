public import Foundation
public import WebKit

/// Creates the WebKit data stores backing profiles. Swappable for tests.
public protocol WebsiteDataStoreFactory {
    /// A persistent store identified by `identifier`. WebKit keeps cookies,
    /// caches, and storage for it in a directory keyed by that UUID.
    func makeStore(identifier: UUID) -> WKWebsiteDataStore
    /// A store that keeps everything in memory (an incognito window).
    func makeNonPersistentStore() -> WKWebsiteDataStore
    /// Deletes every piece of data WebKit holds for `identifier`.
    func removeStore(identifier: UUID) async throws
}

public extension WebsiteDataStoreFactory {
    func makeNonPersistentStore() -> WKWebsiteDataStore { .nonPersistent() }
}

/// The real factory: `WKWebsiteDataStore(forIdentifier:)`.
public struct SystemWebsiteDataStoreFactory: WebsiteDataStoreFactory {
    public init() {}

    public func makeStore(identifier: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: identifier)
    }

    public func removeStore(identifier: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}

/// Maps cmux browser profiles onto WebKit data stores.
///
/// Each `BrowserProfileID` gets exactly one persistent store for the life of
/// the process, keyed by the profile UUID, so tabs of one profile share
/// cookies and tabs of different profiles never do. The default profile uses
/// its own identified store, never `WKWebsiteDataStore.default()`. An
/// off-the-record profile (an incognito window) gets one non-persistent
/// store, dropped with its data when the profile ends.
public final class WebKitProfileStore {
    private let factory: any WebsiteDataStoreFactory
    private let offTheRecord: OffTheRecordProfiles
    private var stores: [BrowserProfileID: WKWebsiteDataStore] = [:]

    public init(factory: any WebsiteDataStoreFactory = SystemWebsiteDataStoreFactory(),
                offTheRecord: OffTheRecordProfiles = .shared) {
        self.factory = factory
        self.offTheRecord = offTheRecord
        offTheRecord.observeEnd { [weak self] profile in self?.stores[profile] = nil }
    }

    /// The store for `profile`, created on first use.
    public func dataStore(for profile: BrowserProfileID) -> WKWebsiteDataStore {
        if let store = stores[profile] { return store }
        let store = offTheRecord.isOffTheRecord(profile)
            ? factory.makeNonPersistentStore()
            : factory.makeStore(identifier: profile.rawValue)
        stores[profile] = store
        return store
    }

    /// Profiles with a live store in this process.
    public var loadedProfiles: Set<BrowserProfileID> {
        Set(stores.keys)
    }

    /// Deletes all website data of a profile. Close its tabs first: WebKit
    /// refuses to remove a store that live web views still use.
    public func removeData(for profile: BrowserProfileID) async throws {
        stores[profile] = nil
        try await factory.removeStore(identifier: profile.rawValue)
    }
}
