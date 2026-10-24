public import Foundation
public import WebKit
import Network

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
    /// Each proxied profile's proxy (#24432); a profile not here is direct.
    private var proxies: [BrowserProfileID: BrowserProfileProxy] = [:]

    public init(factory: any WebsiteDataStoreFactory = SystemWebsiteDataStoreFactory(),
                offTheRecord: OffTheRecordProfiles) {
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
        Self.apply(proxies[profile], to: store)
        stores[profile] = store
        return store
    }

    /// Sets `profile`'s proxy (nil: direct): its live store now, a store made later on creation.
    public func setProxy(_ proxy: BrowserProfileProxy?, for profile: BrowserProfileID) {
        guard proxies[profile] != proxy else { return }
        proxies[profile] = proxy
        if let store = stores[profile] { Self.apply(proxy, to: store) }
    }

    /// The proxy `profile` uses, nil when direct.
    public func proxy(for profile: BrowserProfileID) -> BrowserProfileProxy? { proxies[profile] }

    private static func apply(_ proxy: BrowserProfileProxy?, to store: WKWebsiteDataStore) {
        guard let proxy else {
            store.proxyConfigurations = []
            return
        }
        // A proxy WebKit cannot take goes to a closed port rather than direct (fail closed).
        store.proxyConfigurations = [proxy.webKitConfiguration ?? Self.closedProxy]
    }

    /// A proxy that refuses every connection: the discard port on loopback.
    private static var closedProxy: ProxyConfiguration {
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))
        configuration.allowFailover = false
        return configuration
    }

    /// Whether `profile` is off the record (an incognito window).
    public func isOffTheRecord(_ profile: BrowserProfileID) -> Bool { offTheRecord.isOffTheRecord(profile) }

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

    /// Clear Browsing Data (cx-d0d.23): removes `profile`'s cookies and site
    /// data (storage of every kind) and/or its caches changed since `since`
    /// (nil: all time).
    public func clearBrowsingData(for profile: BrowserProfileID, siteData: Bool, cache: Bool, since: Date?) async {
        var types: Set<String> = []
        if cache { types.formUnion(Self.cacheTypes) }
        if siteData { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(Self.cacheTypes)) }
        guard !types.isEmpty else { return }
        await dataStore(for: profile).removeData(ofTypes: types, modifiedSince: since ?? .distantPast)
    }

    /// The cache kinds of website data (Chrome's "Cached images and files").
    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]

    /// Deletes every record of a deleted profile's store (cookies, storage,
    /// caches) through a store instance. The static
    /// `WKWebsiteDataStore.remove(forIdentifier:)` crashed on WebKit's IO
    /// queue at launch for a store no page used in the process; the empty
    /// container stays behind.
    public func clearData(for profile: BrowserProfileID) async {
        stores[profile] = nil
        let store = factory.makeStore(identifier: profile.rawValue)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
